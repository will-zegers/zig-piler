const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Parser = @import("../Parser.zig");
const TAC = @import("../TAC.zig");

const Symbol = @import("../Semantic.zig").Symbol;

pub const InstructionList = ArrayList(Instruction);

pub const ARG_REGISTERS = [_]Reg{ .di, .si, .dx, .cx, .r8, .r9 };
pub const LONGWORD_BYTES: isize = 4;
pub const QUADWORD_BYTES: isize = 8;

fn funCallToAssembly(allocator: Allocator, symbols: Symbol.Table, funCall: TAC.FunCall) ![]Instruction {
    var assembly: ArrayList(Instruction) = .empty;

    // Define and check how much we need to allocate initially to the stack to make sure it's
    // aligned to 16-bytes on function call, per Sys V ABI
    var allocatedStack: usize = undefined;
    if (funCall.args.len <= ARG_REGISTERS.len) {
        // No stack arguments, so no alignment needed
        allocatedStack = 0;
    } else {
        // Check if we have an even or odd number of stack allocations. If odd, we'll need
        // to allocate an additional 8-bytes to make sure the stack is 16-byte aligned
        if ((funCall.args.len - ARG_REGISTERS.len) % 2 == 0) {
            allocatedStack = 0;
        } else {
            allocatedStack = QUADWORD_BYTES;
            try assembly.append(allocator, .{ .AllocateStack = .{ .stackSpace = allocatedStack } });
        }
    }

    // This process in reverse of the Sys V ABI, pushing stack arguments (if any) first in their reverse
    // order, and then register arguments (if any) in reverse of the specification (similar to GCC)
    var i = funCall.args.len;
    while (i > ARG_REGISTERS.len) { // Push stack arguments (arguments 6 and on) first in reverse order
        i -= 1;
        switch (funCall.args[i]) {
            .Constant => |arg| {
                const imm: i64 = Operand.constantToImm(arg);
                try assembly.append(allocator, .{ .Push = .{ .operand = .{ .Imm = imm } } });
            },
            .Var => |arg| {
                const t = symbols.get(arg).?.type;
                _ = t;
                try assembly.appendSlice(allocator, &.{
                    .{ .Mov = .{ .src = .{ .Pseudo = arg }, .dst = .{ .Reg = .ax } } },
                    .{ .Push = .{ .operand = .{ .Reg = .ax } } },
                });
            },
        }
        allocatedStack += QUADWORD_BYTES;
    }
    while (i > 0) { // Move arguments in corresponding stack registers
        i -= 1;
        switch (funCall.args[i]) {
            .Constant => |arg| {
                const imm: i64 = Operand.constantToImm(arg);
                try assembly.append(allocator, .{ .Mov = .{ .src = .{ .Imm = imm }, .dst = .{ .Reg = ARG_REGISTERS[i] } } });
            },
            .Var => |arg| {
                try assembly.append(allocator, .{ .Mov = .{ .src = .{ .Pseudo = arg }, .dst = .{ .Reg = ARG_REGISTERS[i] } } });
            },
        }
    }

    try assembly.append(allocator, .{ .Call = .{ .identifier = funCall.name } });

    if (allocatedStack > 0) {
        try assembly.append(allocator, .{ .DeallocateStack = .{ .int = allocatedStack } });
    }

    switch (funCall.dst) {
        .Var => |dst| {
            try assembly.append(allocator, .{ .Mov = .{ .src = .{ .Reg = .ax }, .dst = .{ .Pseudo = dst } } });
        },
        .Constant => unreachable,
    }

    return try assembly.toOwnedSlice(allocator);
}

fn signExtend(allocator: Allocator, se: TAC.SignExtend) []Instruction {
    const src: Operand = .fromVal(se.src);
    const dst: Operand = .fromVal(se.dst);

    return allocator.dupe(Instruction, &.{.{ .Movsx = .{ .src = src, .dst = dst } }}) catch allocError();
}

fn truncate(allocator: Allocator, tr: TAC.Truncate) []Instruction {
    const src: Operand = .fromVal(tr.src);
    const dst: Operand = .fromVal(tr.dst);

    return allocator.dupe(Instruction, &.{.{ .Mov = .{ .src = src, .dst = dst } }}) catch allocError();
}

const InstructionTag = enum {
    AllocateStack,
    Binary,
    Call,
    Cdq,
    Cmp,
    DeallocateStack,
    Idiv,
    Jmp,
    JmpCC,
    Label,
    Mov,
    Movsx,
    Push,
    Ret,
    SetCC,
    Unary,
};
pub const Instruction = union(InstructionTag) {
    AllocateStack: AllocateStack,
    Binary: Binary,
    Call: Call,
    Cdq: Cdq,
    Cmp: Cmp,
    DeallocateStack: DeallocateStack,
    Idiv: Idiv,
    Jmp: Jmp,
    JmpCC: JmpCC,
    Label: Label,
    Mov: Mov,
    Movsx: Movsx,
    Push: Push,
    Ret: Ret,
    SetCC: SetCC,
    Unary: Unary,

    pub fn assemble(allocator: Allocator, symbols: Symbol.Table, instruction: TAC.Instruction) []Instruction {
        return switch (instruction) {
            .Binary => Binary.toAssembly(allocator, instruction.Binary),
            .Copy => Mov.toAssembly(allocator, instruction.Copy),
            .FunCall => funCallToAssembly(allocator, symbols, instruction.FunCall) catch allocError(),
            .Jump => Jmp.toAssembly(allocator, instruction.Jump),
            .JumpIfZero, .JumpIfNotZero => JmpCC.toAssembly(allocator, instruction),
            .Label => Label.toAssembly(allocator, instruction.Label),
            .Return => Ret.toAssembly(allocator, instruction.Return),
            .SignExtend => signExtend(allocator, instruction.SignExtend),
            .Truncate => truncate(allocator, instruction.Truncate),
            .Unary => Unary.toAssembly(allocator, instruction.Unary),
        };
    }
};

pub const AllocateStack = struct {
    stackSpace: usize,

    pub fn prepend(allocator: Allocator, stackSpace: isize) []Instruction {
        return allocator.dupe(Instruction, .{.{ .AllocateStack = .{ .stackSpace = stackSpace } }}) catch std.process.exit(0);
    }
};

fn assertTypes2(symbols: Symbol.Table, op1: Operand, op2: Operand) ?Type {
    std.debug.assert(op1 != null and op2 != null);

    if (op1 == null) {
        return switch (op2.?) {
            .Data => symbols.get(op2.Data).?.type,
            .Pseudo => symbols.get(op2.Data).?.type,
            .Imm, .Reg, .Stack => null,
        };
    } else if (op2 == null) {
        return switch (op1.?) {
            .Data => symbols.get(op1.?.Data).?.type,
            .Pseudo => symbols.get(op1.?.Data).?.type,
            .Imm, .Reg, .Stack => null,
        };
    }

    switch (op1) {
        .Data => {
            const op1Type = symbols.get(op1.?.Data).?.type;
            switch (op2.?) {
                .Data => {
                    const op2Type = symbols.get(op2.?.Data).?.type;
                    std.debug.assert(op1Type.equals(op2Type));
                    return op1Type;
                },
                .Pseudo => {
                    const op2Type = symbols.get(op2.?.Pseudo).?.type;
                    std.debug.assert(op1Type.equals(op2Type));
                    return op1Type;
                },
                .Imm, .Reg, .Stack => return op1Type,
            }
        },
        .Pseudo => {
            const op1Type = symbols.get(op1.?.Data).?.type;
            switch (op2.?) {
                .Data => {
                    const op2Type = symbols.get(op2.?.Data).?.type;
                    std.debug.assert(op1Type.equals(op2Type));
                    return op1Type;
                },
                .Pseudo => {
                    const op2Type = symbols.get(op2.?.Pseudo).?.type;
                    std.debug.assert(op1Type.equals(op2Type));
                    return op1Type;
                },
                .Imm, .Reg, .Stack => return op1Type,
            }
        },
        .Imm, .Reg, .Stack => return switch (op2.?) {
            .Data => symbols.get(op2.?.Data).?.type,
            .Pseudo => symbols.get(op2.?.Pseudo).?.type,
            .Imm, .Reg, .Stack => null,
        },
    }
}

fn assertTypes3(op1: Operand, op2: Operand, op3: Operand) Type {
    return assertTypes2(assertTypes2(op1, op2).?, op3).?;
}

fn getType(symbolTable: Symbol.Table, op1: TAC.Val, op2: TAC.Val) Type {
    return blk: switch (op1) {
        .Constant => switch (op1.Constant) {
            .int => switch (op2) {
                .Constant => switch (op2.Constant) {
                    .int => break :blk .Long,
                    else => unreachable,
                },
                .Var => {
                    const t2 = symbolTable.get(op2.Var).?.type;
                    switch (t2) {
                        .Int => break :blk .Long,
                        else => unreachable,
                    }
                },
            },
            .long => switch (op2) {
                .Constant => switch (op2.Constant) {
                    .long => break :blk .Quad,
                    else => unreachable,
                },
                .Var => {
                    const t2 = symbolTable.get(op2.Var).?.type;
                    switch (t2) {
                        .Long => break :blk .Quad,
                        else => unreachable,
                    }
                },
            },
        },
        .Var => {
            const t1 = symbolTable.get(op1.Var).?.type;
            switch (t1) {
                .Int => switch (op2) {
                    .Constant => switch (op2.Constant) {
                        .int => break :blk .Long,
                        else => unreachable,
                    },
                    .Var => {
                        const t2 = symbolTable.get(op2.Var).?.type;
                        switch (t2) {
                            .Int => break :blk .Long,
                            else => unreachable,
                        }
                    },
                },
                .Long => switch (op2) {
                    .Constant => switch (op2.Constant) {
                        .long => break :blk .Quad,
                        else => unreachable,
                    },
                    .Var => {
                        const t2 = symbolTable.get(op2.Var).?.type;
                        switch (t2) {
                            .Long => break :blk .Quad,
                            else => unreachable,
                        }
                    },
                },
                .FunType => unreachable,
            }
        },
    };
}

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;

    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, binary: TAC.Binary) []Instruction {
        const src1: Operand = .fromVal(binary.src1);
        const src2: Operand = .fromVal(binary.src2);
        const dst: Operand = .{ .Pseudo = binary.dst.Var };

        return switch (binary.operator) {
            .Div, .Mod => blk: {
                const sourceReg: Operand = switch (binary.operator) {
                    .Div => .{ .Reg = .ax },
                    .Mod => .{ .Reg = .dx },
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src1, .dst = .{ .Reg = .ax } } },
                    .{ .Cdq = .{} },
                    .{ .Idiv = .{ .operand = src2 } },
                    .{ .Mov = .{ .src = sourceReg, .dst = dst } },
                });
            },
            .Eq, .Gt, .Gte, .Lt, .Lte, .Neq => |op| blk: {
                const cCode: ConditionCode = switch (op) {
                    .Eq => .E,
                    .Gt => .G,
                    .Gte => .GE,
                    .Lt => .L,
                    .Lte => .LE,
                    .Neq => .NE,
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = src2, .arg2 = src1 } },
                    .{ .Mov = .{ .src = .{ .Imm = 0 }, .dst = dst } },
                    .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                });
            },
            .AndL, .OrL => unreachable, // logical AND and OR have no binary instruction, already handled in TACky
            else => allocator.dupe(Instruction, &.{
                .{ .Mov = .{ .src = src1, .dst = dst } },
                .{ .Binary = .{ .operator = binary.operator, .src = src2, .dst = dst } },
            }),
        } catch allocError();
    }
};

pub const Call = struct { identifier: []const u8 };

pub const Cdq = struct {}; // EDX:EAX:= sign-extend of EAX.

pub const Cmp = struct { arg1: Operand, arg2: Operand };

pub const DeallocateStack = struct { int: usize };

pub const Idiv = struct { operand: Operand };

pub const Jmp = struct {
    target: []const u8,

    pub fn toAssembly(allocator: Allocator, jmp: TAC.Jump) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Jmp = .{ .target = jmp.target } }}) catch allocError();
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: []const u8,

    pub fn toAssembly(allocator: Allocator, jmpInstr: TAC.Instruction) []Instruction {
        return switch (jmpInstr) {
            .JumpIfZero => |jz| blk: {
                const arg2: Operand = .fromVal(jz.condition);
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .E, .target = jz.target } },
                }) catch allocError();
            },
            .JumpIfNotZero => |jnz| blk: {
                const arg2: Operand = .fromVal(jnz.condition);
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .NE, .target = jnz.target } },
                }) catch allocError();
            },
            else => unreachable,
        };
    }
};

pub const Label = struct {
    id: []const u8,

    pub fn toAssembly(allocator: Allocator, label: TAC.Label) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Label = .{ .id = label.identifier } }}) catch allocError();
    }
};

pub const Mov = struct {
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, copy: TAC.Copy) []Instruction {
        const src: Operand = .fromVal(copy.src);
        const dst: Operand = .fromVal(copy.dst);

        return allocator.dupe(Instruction, &.{.{ .Mov = .{ .src = src, .dst = dst } }}) catch allocError();
    }
};

/// Sign-extended move (cast 4-byte to 8-byte)
pub const Movsx = struct { src: Operand, dst: Operand };

pub const Push = struct { operand: Operand };

pub const Ret = struct {
    pub fn toAssembly(allocator: Allocator, ret: TAC.Return) []Instruction {
        const val: Operand = .fromVal(ret.val);
        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .src = val, .dst = .{ .Reg = .ax } } },
            .{ .Ret = .{} },
        }) catch allocError();
    }
};

const ConditionCode = enum { E, G, GE, L, LE, NE };
pub const SetCC = struct { condition: ConditionCode, operand: Operand };

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    operator: Operator,
    operand: Operand,

    pub fn toAssembly(allocator: Allocator, unary: TAC.Unary) []Instruction {
        const src: Operand = .fromVal(unary.src);
        const dst: Operand = .{ .Pseudo = unary.dst.Var };

        return allocator.dupe(Instruction, switch (unary.operator) {
            .Not => &.{
                .{ .Cmp = .{ .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                .{ .Mov = .{ .src = .{ .Imm = 0 }, .dst = dst } },
                .{ .SetCC = .{ .condition = .E, .operand = dst } },
            },
            .Negate, .Complement => &.{
                .{ .Mov = .{ .src = src, .dst = .{ .Pseudo = unary.dst.Var } } },
                .{ .Unary = .{ .operator = unary.operator, .operand = dst } },
            },
            .Dec, .Inc => &.{
                .{ .Unary = .{ .operator = unary.operator, .operand = src } },
            },
        }) catch allocError();
    }
};

const OperandTag = enum { Imm, Reg, Pseudo, Stack, Data };
pub const Operand = union(OperandTag) {
    Imm: i64,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,
    Data: []const u8,

    pub fn fromVal(val: TAC.Val) Operand {
        return switch (val) {
            .Constant => |constant| .{ .Imm = switch (constant) {
                .int => constant.int,
                .long => constant.long,
            } },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
    }

    pub fn constantToImm(constant: TAC.Constant) i64 {
        return switch (constant) {
            .int => constant.int,
            .long => constant.long,
        };
    }
};

pub const Reg = enum { ax, cx, cl, dx, di, si, r8, r9, r10, r11 };

const Type = enum { Long, Quad };

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
