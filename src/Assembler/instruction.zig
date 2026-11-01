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

const InstructionTag = enum {
    Binary,
    Call,
    Cdq,
    Cmp,
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
    Binary: Binary,
    Call: Call,
    Cdq: Cdq,
    Cmp: Cmp,
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
            .Binary => Binary.toAssembly(allocator, symbols, instruction.Binary),
            .Copy => Mov.toAssembly(allocator, symbols, instruction.Copy),
            .FunCall => funCallToAssembly(allocator, symbols, instruction.FunCall) catch allocError(),
            .Jump => Jmp.toAssembly(allocator, instruction.Jump),
            .JumpIfZero, .JumpIfNotZero => JmpCC.toAssembly(allocator, symbols, instruction),
            .Label => Label.toAssembly(allocator, instruction.Label),
            .Return => Ret.toAssembly(allocator, symbols, instruction.Return),
            .SignExtend => signExtend(allocator, symbols, instruction.SignExtend),
            .Truncate => truncate(allocator, symbols, instruction.Truncate),
            .Unary => Unary.toAssembly(allocator, symbols, instruction.Unary),
        };
    }
};

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;

    type: Type,
    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, binary: TAC.Binary) []Instruction {
        const src1: Operand = .fromVal(binary.src1);
        const src2: Operand = .fromVal(binary.src2);
        const dst: Operand = .{ .Pseudo = binary.dst.Var };
        const dstType: Type = .fromVar(symbols, binary.dst.Var);
        assertTypes(symbols, src1, dst);
        assertTypes(symbols, src2, dst);

        return switch (binary.operator) {
            .Div, .Mod => blk: {
                const sourceReg: Operand = switch (binary.operator) {
                    .Div => .{ .Reg = .ax },
                    .Mod => .{ .Reg = .dx },
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .type = dstType, .src = src1, .dst = .{ .Reg = .ax } } },
                    .{ .Cdq = .{ .type = dstType } },
                    .{ .Idiv = .{ .type = dstType, .operand = src2 } },
                    .{ .Mov = .{ .type = dstType, .src = sourceReg, .dst = dst } },
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
                const srcType: Type = .fromVal(symbols, binary.src1);
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = srcType, .arg1 = src2, .arg2 = src1 } },
                    .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                    .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                });
            },
            .AndL, .OrL => unreachable, // logical AND and OR have no binary instruction, already handled in TACky
            else => allocator.dupe(Instruction, &.{
                .{ .Mov = .inferType(symbols, src1, dst) },
                .{ .Binary = .{ .type = dstType, .operator = binary.operator, .src = src2, .dst = dst } },
            }),
        } catch allocError();
    }
};

pub const Call = struct { identifier: []const u8 };

pub const Cdq = struct { type: Type }; // nX:AX:= sign-extend of AX.

pub const Cmp = struct { type: Type, arg1: Operand, arg2: Operand };

pub const Idiv = struct { type: Type, operand: Operand };

pub const Jmp = struct {
    target: []const u8,

    pub fn toAssembly(allocator: Allocator, jmp: TAC.Jump) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Jmp = .{ .target = jmp.target } }}) catch allocError();
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: []const u8,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, jmpInstr: TAC.Instruction) []Instruction {
        return switch (jmpInstr) {
            .JumpIfZero => |jz| blk: {
                const arg2: Operand = .fromVal(jz.condition);
                const t: Type = .fromVal(symbols, jz.condition);

                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .E, .target = jz.target } },
                }) catch allocError();
            },
            .JumpIfNotZero => |jnz| blk: {
                const arg2: Operand = .fromVal(jnz.condition);
                const t: Type = .fromVal(symbols, jnz.condition);

                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
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
    type: Type,
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, copy: TAC.Copy) []Instruction {
        const src: Operand = .fromVal(copy.src);
        const dst: Operand = .fromVal(copy.dst);

        return allocator.dupe(Instruction, &.{.{ .Mov = .inferType(symbols, src, dst) }}) catch allocError();
    }

    pub fn inferType(symbols: Symbol.Table, src: Operand, dst: Operand) Mov {
        assertTypes(symbols, src, dst);

        var t = dst.getType(symbols);
        if (t == null) t = src.getType(symbols);

        return .{ .type = t.?, .src = src, .dst = dst };
    }
};

/// Sign-extended move (cast 4-byte to 8-byte)
pub const Movsx = struct { type: Type, src: Operand, dst: Operand };

pub const Push = struct { operand: Operand };

pub const Ret = struct {
    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, ret: TAC.Return) []Instruction {
        const val: Operand = .fromVal(ret.val);
        const t: Type = .fromVal(symbols, ret.val);

        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = t, .src = val, .dst = .{ .Reg = .ax } } },
            .{ .Ret = .{} },
        }) catch allocError();
    }
};

const ConditionCode = enum { E, G, GE, L, LE, NE };
pub const SetCC = struct { condition: ConditionCode, operand: Operand };

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    type: Type,
    operator: Operator,
    operand: Operand,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, unary: TAC.Unary) []Instruction {
        const src: Operand = .fromVal(unary.src);
        const srcType: Type = .fromVal(symbols, unary.src);
        const dst: Operand = .{ .Pseudo = unary.dst.Var };
        const dstType: Type = .fromVal(symbols, unary.dst);

        switch (unary.operator) {
            .Not => {},
            else => assertTypes(symbols, src, dst),
        }

        return allocator.dupe(Instruction, switch (unary.operator) {
            .Not => &.{
                .{ .Cmp = .{ .type = srcType, .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                .{ .SetCC = .{ .condition = .E, .operand = dst } },
            },
            .Negate, .Complement => &.{
                .{ .Mov = .inferType(symbols, src, dst) },
                .{ .Unary = .{ .type = dstType, .operator = unary.operator, .operand = dst } },
            },
            .Dec, .Inc => &.{
                .{ .Unary = .{ .type = srcType, .operator = unary.operator, .operand = src } },
            },
        }) catch allocError();
    }
};

const OperandTag = enum { Imm, Reg, Pseudo, Stack, Data };
pub const Operand = union(OperandTag) {
    Imm: usize,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,
    Data: []const u8,

    pub fn fromVal(val: TAC.Val) Operand {
        return switch (val) {
            .Constant => .{ .Imm = constantToImm(val.Constant) },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
    }

    pub fn constantToImm(constant: TAC.Constant) usize {
        return switch (constant) {
            .int => @intCast(constant.int),
            .long => @intCast(constant.long),
        };
    }

    pub fn getType(self: Operand, symbols: Symbol.Table) ?Type {
        return switch (self) {
            .Data => .fromVar(symbols, self.Data),
            .Pseudo => .fromVar(symbols, self.Pseudo),
            .Imm, .Reg, .Stack => null,
        };
    }
};

pub const Reg = enum { ax, cx, cl, dx, di, si, r8, r9, r10, r11, sp };

pub const Type = enum {
    Long,
    Quad,

    pub fn fromVar(symbols: Symbol.Table, v: TAC.Var) Type {
        return switch (symbols.get(v).?.type) {
            .Int => .Long,
            .Long => .Quad,
            .FunType => unreachable,
        };
    }

    pub fn fromConstant(constant: TAC.Constant) Type {
        return switch (constant) {
            .int => .Long,
            .long => .Quad,
        };
    }

    pub fn fromVal(symbols: Symbol.Table, v: TAC.Val) Type {
        return switch (v) {
            .Var => fromVar(symbols, v.Var),
            .Constant => fromConstant(v.Constant),
        };
    }
};

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}

fn assertTypes(symbols: Symbol.Table, op1: Operand, op2: Operand) void {
    const type1 = op1.getType(symbols);
    const type2 = op2.getType(symbols);

    if (type1) |t1| {
        if (type2) |t2| {
            if (t1 != t2) {
                switch (op1) {
                    .Imm => std.debug.print("Imm({d})", .{op1.Imm}),
                    .Pseudo => std.debug.print("Pseudo({s})", .{op1.Pseudo}),
                    .Reg => std.debug.print("Reg({s})", .{@tagName(op1.Reg)}),
                    .Stack => std.debug.print("Stack({d})", .{op1.Stack}),
                    .Data => std.debug.print("Data({s}) ", .{op1.Data}),
                }
                std.debug.print("\n", .{});
                switch (op2) {
                    .Imm => std.debug.print("Imm({d})", .{op2.Imm}),
                    .Pseudo => std.debug.print("Pseudo({s})", .{op2.Pseudo}),
                    .Reg => std.debug.print("Reg({s})", .{@tagName(op2.Reg)}),
                    .Stack => std.debug.print("Stack({d})", .{op2.Stack}),
                    .Data => std.debug.print("Data({s}) ", .{op2.Data}),
                }
                std.debug.print("\n", .{});
                std.log.err("Mismatched types: {any} and {any}\n", .{ t1, t2 });
                std.process.exit(1);
            }
        }
    } else if (type1 != null and type2 != null) {
        std.log.err("Missing types", .{});
        std.process.exit(1);
    }
}

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
            try assembly.append(allocator, .{ .Binary = .{
                .type = .Quad,
                .operator = .Sub,
                .src = .{ .Imm = allocatedStack },
                .dst = .{ .Reg = .sp },
            } });
        }
    }

    // This process in reverse of the Sys V ABI, pushing stack arguments (if any) first in their reverse
    // order, and then register arguments (if any) in reverse of the specification (similar to GCC)
    var i = funCall.args.len;
    while (i > ARG_REGISTERS.len) { // Push stack arguments (arguments 6 and on) first in reverse order
        i -= 1;
        switch (funCall.args[i]) {
            .Constant => |arg| {
                const imm = Operand.constantToImm(arg);
                try assembly.append(allocator, .{ .Push = .{ .operand = .{ .Imm = imm } } });
            },
            .Var => |arg| {
                switch (Type.fromVar(symbols, arg)) {
                    .Long => {
                        try assembly.appendSlice(allocator, &.{ .{ .Mov = .inferType(symbols, .{ .Pseudo = arg }, .{ .Reg = .ax }) }, .{ .Push = .{ .operand = .{ .Reg = .ax } } } });
                    },
                    .Quad => {
                        try assembly.append(allocator, .{ .Push = .{ .operand = .{ .Pseudo = arg } } });
                    },
                }
            },
        }
        allocatedStack += QUADWORD_BYTES;
    }
    while (i > 0) { // Move arguments in corresponding stack registers
        i -= 1;
        switch (funCall.args[i]) {
            .Constant => |arg| {
                const imm = Operand.constantToImm(arg);
                const t: Type = .fromConstant(arg);
                try assembly.append(allocator, .{ .Mov = .{ .type = t, .src = .{ .Imm = imm }, .dst = .{ .Reg = ARG_REGISTERS[i] } } });
            },
            .Var => |arg| {
                const t: Type = .fromVar(symbols, arg);
                try assembly.append(allocator, .{ .Mov = .{ .type = t, .src = .{ .Pseudo = arg }, .dst = .{ .Reg = ARG_REGISTERS[i] } } });
            },
        }
    }

    try assembly.append(allocator, .{ .Call = .{ .identifier = funCall.name } });

    if (allocatedStack > 0) {
        try assembly.append(allocator, .{ .Binary = .{
            .type = .Quad,
            .operator = .Add,
            .src = .{ .Imm = allocatedStack },
            .dst = .{ .Reg = .sp },
        } });
    }

    switch (funCall.dst) {
        .Var => |dst| {
            try assembly.append(allocator, .{ .Mov = .inferType(symbols, .{ .Reg = .ax }, .{ .Pseudo = dst }) });
        },
        .Constant => unreachable,
    }

    return try assembly.toOwnedSlice(allocator);
}

fn signExtend(allocator: Allocator, symbols: Symbol.Table, se: TAC.SignExtend) []Instruction {
    const src: Operand = .fromVal(se.src);
    const dst: Operand = .fromVal(se.dst);
    const t: Type = .fromVal(symbols, se.dst);

    return allocator.dupe(Instruction, &.{.{ .Movsx = .{ .type = t, .src = src, .dst = dst } }}) catch allocError();
}

fn truncate(allocator: Allocator, symbols: Symbol.Table, tr: TAC.Truncate) []Instruction {
    const src: Operand = .fromVal(tr.src);
    const dst: Operand = .fromVal(tr.dst);
    _ = symbols;
    const t: Type = .Long;

    return allocator.dupe(Instruction, &.{.{ .Mov = .{ .type = t, .src = src, .dst = dst } }}) catch allocError();
}
