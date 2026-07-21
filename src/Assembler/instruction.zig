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

    pub fn assembly(allocator: Allocator, copy: TAC.Copy) []Instruction {
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

pub const Ret = struct {
    pub fn assembly(allocator: Allocator, ret: TAC.Return) []Instruction {
        const val: Operand = switch (ret.val) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };

        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .src = val, .dst = .{ .Reg = .rax } } },
            .{ .Ret = .{} },
        }) catch allocError();
    }
};

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    operator: Operator,
    operand: Operand,

    pub fn assembly(allocator: Allocator, unary: TAC.Unary) []Instruction {
        const src: Operand = switch (unary.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
        const dst: Operand = .{ .Pseudo = unary.dst.Var };
        return switch (unary.operator) {
            .Not => allocator.dupe(Instruction, &.{
                .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = src } },
                .{ .Mov = .{ .src = .{ .Imm = "0" }, .dst = dst } },
                .{ .SetCC = .{ .condition = .E, .operand = dst } },
            }),
            else => allocator.dupe(Instruction, &.{
                .{ .Mov = .{ .src = src, .dst = .{ .Pseudo = unary.dst.Var } } },
                .{ .Unary = .{ .operator = unary.operator, .operand = dst } },
            }),
        } catch allocError();
    }
};

pub const AllocStack = struct {
    stackPointer: isize,

    pub fn prepend(allocator: Allocator, stackPointer: isize) []Instruction {
        return allocator.dupe(Instruction, .{.{ .AllocStack = .{ .stackPointer = stackPointer } }}) catch std.process.exit(0);
    }
};

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;

    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn assembly(allocator: Allocator, binary: TAC.Binary) []Instruction {
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
                    .Div => .{ .Reg = .rax },
                    .Mod => .{ .Reg = .rdx },
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src1, .dst = .{ .Reg = .rax } } },
                    .{ .Cqo = .{} },
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
                    .{ .Mov = .{ .src = .{ .Imm = "0" }, .dst = dst } },
                    .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                });
            },
            .AndL, .OrL => unreachable, // logical AND and OR should not have a binary instruction
            else => allocator.dupe(Instruction, &.{
                .{ .Mov = .{ .src = src1, .dst = dst } },
                .{ .Binary = .{ .operator = binary.operator, .src = src2, .dst = dst } },
            }),
        } catch allocError();
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

    pub fn assembly(allocator: Allocator, jmp: TAC.Jump) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Jmp = .{ .target = jmp.target } }}) catch allocError();
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: Identifier,

    pub fn assembly(allocator: Allocator, jmpInstr: TAC.Instruction) []Instruction {
        return switch (jmpInstr) {
            .JumpIfZero => |jz| blk: {
                const arg2: Operand = switch (jz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .E, .target = jz.target } },
                }) catch allocError();
            },
            .JumpIfNotZero => |jnz| blk: {
                const arg2: Operand = switch (jnz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = arg2 } },
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

    pub fn assembly(allocator: Allocator, label: TAC.Label) []Instruction {
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
    Imm: []const u8,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,
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

fn allocError() noreturn {
    @panic("Memory allocation error");
}
