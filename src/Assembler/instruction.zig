const std = @import("std");
const Allocator = std.mem.Allocator;

const TAC = @import("../TAC.zig");

pub const Instructions = std.ArrayList(Instruction);

const InstructionTag = enum {
    Mov,
    Ret,
    Unary,
    AllocStack,
    Binary,
    Cqo,
    Idiv,
    Cmp,
    Jmp,
    JmpCC,
    SetCC,
    Label,
};
pub const Instruction = union(InstructionTag) {
    Mov: Mov,
    Ret: Ret,
    Unary: Unary,
    AllocStack: AllocStack,
    Binary: Binary,
    Cqo: Cqo,
    Idiv: Idiv,
    Cmp: Cmp,
    Jmp: Jmp,
    JmpCC: JmpCC,
    SetCC: SetCC,
    Label: Label,
};

pub const Mov = struct {
    src: Operand,
    dst: Operand,

    pub fn append(allocator: Allocator, instructions: *Instructions, copy: TAC.Copy) void {
        const src: Operand = switch (copy.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const dst: Operand = switch (copy.dst) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        instructions.append(allocator, .{ .Mov = .{ .src = src, .dst = dst } }) catch std.process.exit(1);
    }
};

pub const Ret = struct {
    pub fn append(allocator: Allocator, instructions: *Instructions, ret: TAC.Return) void {
        const val: Operand = switch (ret.val) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };

        instructions.appendSlice(
            allocator,
            &.{
                .{ .Mov = .{ .src = val, .dst = .{ .Reg = .rax } } },
                .{ .Ret = .{} },
            },
        ) catch std.process.exit(1);
    }
};

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    operator: Operator,
    operand: Operand,

    pub fn append(allocator: Allocator, instructions: *Instructions, unary: TAC.Unary) void {
        const src: Operand = switch (unary.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const dst: Operand = .{ .Pseudo = unary.dst.Var };
        const instrSlice = switch (unary.operator) {
            .Not => blk: {
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = src } },
                    .{ .Mov = .{ .src = .{ .Imm = "0" }, .dst = dst } },
                    .{ .SetCC = .{ .condition = .E, .operand = dst } },
                }) catch std.process.exit(1);
            },
            else => blk: {
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src, .dst = .{ .Pseudo = unary.dst.Var } } },
                    .{ .Unary = .{ .operator = unary.operator, .operand = dst } },
                }) catch std.process.exit(1);
            },
        };
        defer allocator.free(instrSlice);
        instructions.appendSlice(allocator, instrSlice) catch std.process.exit(1);
    }
};

pub const AllocStack = struct {
    stackPointer: isize,

    pub fn prepend(allocator: Allocator, stackPointer: isize, instructions: *Instructions) void {
        instructions.insert(allocator, 0, .{ .AllocStack = .{ .stackPointer = stackPointer } }) catch std.process.exit(0);
    }
};

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;

    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn append(allocator: Allocator, instructions: *Instructions, binary: TAC.Binary) void {
        const src1: Operand = switch (binary.src1) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const src2: Operand = switch (binary.src2) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const dst: Operand = .{ .Pseudo = binary.dst.Var };

        const instruction = switch (binary.operator) {
            .Div,
            .Mod,
            => blk: {
                const sourceReg: Operand = switch (binary.operator) {
                    .Div => .{ .Reg = .rax },
                    .Mod => .{ .Reg = .rdx },
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src1, .dst = .{ .Reg = .rax } } },
                    .{ .Cqo = .{} },
                    .{ .Idiv = .{ .operand = src2 } },
                    .{ .Mov = .{ .src = sourceReg, .dst = dst } },
                }) catch std.process.exit(1);
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
                    .{ .Mov = .{ .src = .{ .Imm = "0" }, .dst = dst } },
                    .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                }) catch std.process.exit(1);
            },
            .AndL, .OrL => unreachable, // logical AND and OR should not have a binary instruction
            else => blk: {
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src1, .dst = dst } },
                    .{ .Binary = .{ .operator = binary.operator, .src = src2, .dst = dst } },
                }) catch std.process.exit(1);
            },
        };
        defer allocator.free(instruction);

        instructions.appendSlice(allocator, instruction) catch std.process.exit(1);
    }
};

pub const Cqo = struct {};

pub const Idiv = struct { operand: Operand };

pub const Cmp = struct {
    arg1: Operand,
    arg2: Operand,
};

pub const Jmp = struct {
    target: Identifier,

    pub fn append(allocator: Allocator, instructions: *Instructions, jmp: TAC.Jump) void {
        instructions.append(allocator, .{ .Jmp = .{ .target = jmp.target } }) catch std.process.exit(1);
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: Identifier,

    pub fn append(allocator: Allocator, instructions: *Instructions, jmpInstr: TAC.Instruction) void {
        switch (jmpInstr) {
            .JumpIfZero => |jz| {
                const arg2: Operand = switch (jz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                instructions.appendSlice(allocator, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .E, .target = jz.target } },
                }) catch std.process.exit(1);
            },
            .JumpIfNotZero => |jnz| {
                const arg2: Operand = switch (jnz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                instructions.appendSlice(allocator, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .NE, .target = jnz.target } },
                }) catch std.process.exit(1);
            },
            else => unreachable,
        }
    }
};

pub const SetCC = struct { condition: ConditionCode, operand: Operand };

pub const Label = struct {
    id: Identifier,

    pub fn append(allocator: Allocator, instructions: *Instructions, label: TAC.Label) void {
        instructions.append(allocator, .{ .Label = .{ .id = label.identifier } }) catch std.process.exit(1);
    }
};

const OperandType = enum {
    Imm,
    Reg,
    Pseudo,
    Stack,
};
pub const Operand = union(OperandType) {
    Imm: []const u8,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,

    pub fn isPseudo(self: Operand) bool {
        return self == Operand.Pseudo;
    }

    pub fn isStack(self: Operand) bool {
        return self == Operand.Stack;
    }

    pub fn isImm(self: Operand) bool {
        return self == Operand.Imm;
    }
};

pub const Reg = enum {
    rax,
    al,
    rcx,
    cl,
    rdx,
    dl,
    r10,
    r10b,
    r11,
    r11b,

    pub fn toByteRegister(operand: Operand) Operand {
        return switch (operand) {
            .Reg => |reg| switch (reg) {
                .rax => .{ .Reg = .al },
                .rcx => .{ .Reg = .cl },
                .rdx => .{ .Reg = .dl },
                .r10 => .{ .Reg = .r10b },
                .r11 => .{ .Reg = .r11b },
                else => operand,
            },
            else => operand,
        };
    }
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
