const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const TAC = @import("../TAC.zig");

pub const InstructionList = ArrayList(Instruction);

pub const ARG_REGISTERS = [_]Reg{ .di, .si, .dx, .cx, .r8, .r9 };

const InstructionTag = enum {
    Mov,
    Push,
    Call,
    Ret,
    Unary,
    AllocateStack,
    DeallocateStack,
    Binary,
    Cdq,
    Idiv,
    Cmp,
    Jmp,
    JmpCC,
    SetCC,
    Label,
};
pub const Instruction = union(InstructionTag) {
    Mov: Mov,
    Push: Push,
    Call: Call,
    Ret: Ret,
    Unary: Unary,
    AllocateStack: AllocateStack,
    DeallocateStack: DeallocateStack,
    Binary: Binary,
    Cdq: Cdq,
    Idiv: Idiv,
    Cmp: Cmp,
    Jmp: Jmp,
    JmpCC: JmpCC,
    SetCC: SetCC,
    Label: Label,
};

pub fn funCallToAssembly(allocator: Allocator, funCall: TAC.FunCall) ![]Instruction {
    var assembly: ArrayList(Instruction) = .empty;

    // Define and check how much we need to allocate initially to the stack to make sure it's
    // aligned to 16-bytes on function call, per Sys V ABI
    var allocatedStack: isize = undefined;
    if (funCall.args.len <= ARG_REGISTERS.len) {
        // No stack arguments, so no alignment needed
        allocatedStack = 0;
    } else {
        // Check if we have an even or odd number of stack allocations. If odd, we'll need
        // to allocate an additional 8-bytes to make sure the stack is 16-byte aligned
        if ((funCall.args.len - ARG_REGISTERS.len) % 2 == 0) {
            allocatedStack = 0;
        } else {
            allocatedStack = 8;
            try assembly.append(allocator, .{ .AllocateStack = .{ .stackPointer = allocatedStack } });
        }
    }

    // This process in reverse of the Sys V ABI, pushing stack arguments (if any) first in their reverse
    // order, and then register arguments (if any) in reverse of the specification (similar to GCC)
    var i = funCall.args.len;
    while (i > ARG_REGISTERS.len) { // Push stack arguments (arguments 6 and on) first in reverse order
        i -= 1;
        switch (funCall.args[i]) {
            .Constant => |arg| {
                try assembly.append(allocator, .{ .Push = .{ .operand = .{ .Imm = arg } } });
            },
            .Var => |arg| {
                try assembly.appendSlice(allocator, &.{
                    .{ .Mov = .{ .src = .{ .Pseudo = arg }, .dst = .{ .Reg = .ax } } },
                    .{ .Push = .{ .operand = .{ .Reg = .ax } } },
                });
            },
        }
        allocatedStack += 8;
    }
    while (i > 0) { // Move arguments in corresponding stack registers
        i -= 1;
        switch (funCall.args[i]) {
            .Constant => |arg| {
                try assembly.append(allocator, .{ .Mov = .{ .src = .{ .Imm = arg }, .dst = .{ .Reg = ARG_REGISTERS[i] } } });
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

pub const Mov = struct {
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, copy: TAC.Copy) []Instruction {
        const src: Operand = switch (copy.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const dst: Operand = switch (copy.dst) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        return allocator.dupe(Instruction, &.{.{ .Mov = .{ .src = src, .dst = dst } }}) catch allocError();
    }
};

pub const Push = struct {
    operand: Operand,
};

pub const Call = struct {
    identifier: Identifier,
};

pub const Ret = struct {
    pub fn toAssembly(allocator: Allocator, ret: TAC.Return) []Instruction {
        const val: Operand = switch (ret.val) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };

        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .src = val, .dst = .{ .Reg = .ax } } },
            .{ .Ret = .{} },
        }) catch allocError();
    }
};

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    operator: Operator,
    operand: Operand,

    pub fn toAssembly(allocator: Allocator, unary: TAC.Unary) []Instruction {
        const src: Operand = switch (unary.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
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

pub const AllocateStack = struct {
    stackPointer: isize,

    pub fn prepend(allocator: Allocator, stackPointer: isize) []Instruction {
        return allocator.dupe(Instruction, .{.{ .AllocateStack = .{ .stackPointer = stackPointer } }}) catch std.process.exit(0);
    }
};

pub const DeallocateStack = struct {
    int: isize,
};

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;

    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, binary: TAC.Binary) []Instruction {
        const src1: Operand = switch (binary.src1) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const src2: Operand = switch (binary.src2) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const dst: Operand = .{ .Pseudo = binary.dst.Var };

        return switch (binary.operator) {
            .Div,
            .Mod,
            => blk: {
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

pub const Cdq = struct {}; // EDX:EAX:= sign-extend of EAX.

pub const Idiv = struct { operand: Operand };

pub const Cmp = struct {
    arg1: Operand,
    arg2: Operand,
};

pub const Jmp = struct {
    target: Identifier,

    pub fn toAssembly(allocator: Allocator, jmp: TAC.Jump) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Jmp = .{ .target = jmp.target } }}) catch allocError();
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: Identifier,

    pub fn toAssembly(allocator: Allocator, jmpInstr: TAC.Instruction) []Instruction {
        return switch (jmpInstr) {
            .JumpIfZero => |jz| blk: {
                const arg2: Operand = switch (jz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .E, .target = jz.target } },
                }) catch allocError();
            },
            .JumpIfNotZero => |jnz| blk: {
                const arg2: Operand = switch (jnz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .NE, .target = jnz.target } },
                }) catch allocError();
            },
            else => unreachable,
        };
    }
};

pub const SetCC = struct { condition: ConditionCode, operand: Operand };

pub const Label = struct {
    id: Identifier,

    pub fn toAssembly(allocator: Allocator, label: TAC.Label) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Label = .{ .id = label.identifier } }}) catch allocError();
    }
};

const OperandType = enum {
    Imm,
    Reg,
    Pseudo,
    Stack,
};
pub const Operand = union(OperandType) {
    Imm: usize,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,
};

pub const Reg = enum {
    ax,
    cx,
    cl,
    dx,
    di,
    si,
    r8,
    r9,
    r10,
    r11,
};

const Identifier = []const u8;

const ConditionCode = enum {
    E,
    G,
    GE,
    L,
    LE,
    NE,
};

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
