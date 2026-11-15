const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const math = std.math;

const Parser = @import("../Parser.zig");
const Symbol = @import("../Semantic.zig").Symbol;
const TAC = @import("../TAC.zig");

const operands = @import("operands.zig");
const Operand = operands.Operand;
const Reg = operands.Reg;
const StaticConstant = operands.StaticConstant;
const StaticVariable = operands.StaticConstant;
const Type = operands.Type;
const TypedOperand = operands.TypedOperand;

pub const ARG_INT_REGISTERS = [_]Reg{ .di, .si, .dx, .cx, .r8, .r9 };
pub const ARG_FP_REGISTERS = [_]Reg{
    .xmm0, .xmm1, .xmm2, .xmm3,
    .xmm4, .xmm5, .xmm6, .xmm7,
};
pub const LONGWORD_BYTES: isize = 4;
pub const QUADWORD_BYTES: isize = 8;
const UPPER_BOUND_Q: f64 = 9223372036854775808.0;

var counter: usize = 0;
const InstructionTag = enum {
    Binary,
    Call,
    Cdq,
    Cmp,
    Cvtsi2sd,
    Cvttsd2si,
    Div,
    Idiv,
    Jmp,
    JmpCC,
    Label,
    Mov,
    Movsx,
    Movzx,
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
    Cvtsi2sd: Cvtsi2sd,
    Cvttsd2si: Cvttsd2si,
    Div: Div,
    Idiv: Idiv,
    Jmp: Jmp,
    JmpCC: JmpCC,
    Label: Label,
    Mov: Mov,
    Movsx: Movsx,
    Movzx: Movzx,
    Push: Push,
    Ret: Ret,
    SetCC: SetCC,
    Unary: Unary,

    pub fn assemble(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), instruction: TAC.Instruction) Allocator.Error![]Instruction {
        return switch (instruction) {
            .Binary => Binary.toAssembly(allocator, symbols, staticConstsByValue, instruction.Binary),
            .Copy => Mov.toAssembly(allocator, symbols, staticConstsByValue, instruction.Copy),
            .DoubleToInt => Cvttsd2si.toAssemblySigned(allocator, symbols, staticConstsByValue, instruction.DoubleToInt),
            .DoubleToUInt => Cvttsd2si.toAssemblyUnsigned(allocator, symbols, staticConstsByValue, instruction.DoubleToUInt),
            .FunCall => funCallToAssembly(allocator, symbols, staticConstsByValue, instruction.FunCall),
            .IntToDouble => Cvtsi2sd.toAssemblySigned(allocator, symbols, staticConstsByValue, instruction.IntToDouble),
            .Jump => Jmp.toAssembly(allocator, instruction.Jump),
            .JumpIfZero, .JumpIfNotZero => JmpCC.toAssembly(allocator, symbols, staticConstsByValue, instruction),
            .Label => Label.toAssembly(allocator, instruction.Label),
            .Return => Ret.toAssembly(allocator, symbols, staticConstsByValue, instruction.Return),
            .SignExtend => signExtend(allocator, symbols, staticConstsByValue, instruction.SignExtend),
            .Truncate => truncate(allocator, staticConstsByValue, instruction.Truncate),
            .UIntToDouble => Cvtsi2sd.toAssemblyUnsigned(allocator, symbols, staticConstsByValue, instruction.UIntToDouble),
            .Unary => Unary.toAssembly(allocator, symbols, staticConstsByValue, instruction.Unary),
            .ZeroExtend => zeroExtend(allocator, staticConstsByValue, instruction.ZeroExtend),
        };
    }

    pub fn getType(self: Instruction) ?Type {
        return switch (self) {
            .Binary => self.Binary.type,
            .Cdq => self.Cdq.type,
            .Cmp => self.Cmp.type,
            .Cvtsi2sd => self.Cvtsi2sd.type,
            .Cvttsd2si => self.Cvttsd2si.type,
            .Div => self.Div.type,
            .Idiv => self.Idiv.type,
            .Mov => self.Mov.type,
            .Movsx => self.Movsx.type,
            .Movzx => self.Movzx.type,
            .Push => self.Push.type,
            .Ret => self.Ret.type,
            .Unary => self.Unary.type,
            .Call, .Jmp, .JmpCC, .Label, .SetCC => null,
        };
    }
};

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;
    const LIST_SIZE = 8;

    type: Type,
    operator: Operator,
    src: Operand,
    dst: Operand,

    // TODO: this all could use some cleanup
    fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), binary: TAC.Binary) Allocator.Error![]Instruction {
        var instructions = try ArrayList(Instruction).initCapacity(allocator, LIST_SIZE);

        const src1 = try Operand.fromVal(allocator, staticConstsByValue, binary.src1);
        const src2 = try Operand.fromVal(allocator, staticConstsByValue, binary.src2);
        const dst: Operand = .{ .Pseudo = binary.dst.Var };

        const isSigned: bool = switch (binary.src1) {
            .Var => |v| symbols.get(v).?.type.isSignedInteger(),
            .Constant => |c| switch (c) {
                .double, .uint, .ulong => false,
                .int, .long => true,
            },
        };
        const t = Type.fromVal(symbols, binary.src1);
        const srcType = Type.fromVal(symbols, binary.src1);
        const dstType = Type.fromVal(symbols, binary.dst);

        switch (binary.operator) {
            .Div, .Mod => {
                if (t == .Double) {
                    instructions.appendSliceAssumeCapacity(&.{
                        .{ .Mov = .{ .type = t, .src = src1, .dst = dst } },
                        .{ .Binary = .{ .type = t, .operator = binary.operator, .src = src2, .dst = dst } },
                    });
                } else {
                    const result: Operand = switch (binary.operator) {
                        .Div => .{ .Reg = .ax },
                        .Mod => .{ .Reg = .dx },
                        else => unreachable,
                    };
                    if (isSigned) { // sign-extend and issue idiv (isSigned) instruction
                        instructions.appendSliceAssumeCapacity(&.{
                            .{ .Mov = .{ .type = t, .src = src1, .dst = .{ .Reg = .ax } } },
                            .{ .Cdq = .{ .type = t } },
                            .{ .Idiv = .{ .type = t, .operand = src2 } },
                            .{ .Mov = .{ .type = t, .src = result, .dst = dst } },
                        });
                    } else { // zero-extend and issue div (unsigned) instruction
                        instructions.appendSliceAssumeCapacity(&.{
                            .{ .Mov = .{ .type = t, .src = src1, .dst = .{ .Reg = .ax } } },
                            .{ .Mov = .{ .type = t, .src = .{ .Imm = 0 }, .dst = .{ .Reg = .dx } } },
                            .{ .Div = .{ .type = t, .operand = src2 } },
                            .{ .Mov = .{ .type = t, .src = result, .dst = dst } },
                        });
                    }
                }
            },
            .Eq, .Gt, .Gte, .Lt, .Lte, .Neq => |op| {
                const cCode: ConditionCode = switch (op) {
                    .Eq => .e,
                    .Gt => if (!isSigned) .a else .g,
                    .Gte => if (!isSigned) .ae else .ge,
                    .Lt => if (!isSigned) .b else .l,
                    .Lte => if (!isSigned) .be else .le,
                    .Neq => .ne,
                    else => unreachable,
                };
                switch (t) {
                    .Double => {
                        instructions.appendSliceAssumeCapacity(&.{
                            .{ .Cmp = .{ .type = .Double, .arg1 = src2, .arg2 = src1 } },
                            .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                            .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                        });
                    },
                    .Long, .Quad => {
                        instructions.appendSliceAssumeCapacity(&.{
                            .{ .Cmp = .{ .type = srcType, .arg1 = src2, .arg2 = src1 } },
                            .{ .Mov = .{ .type = dstType, .src = .{ .Imm = 0 }, .dst = dst } },
                            .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                        });
                    },
                }
            },
            .AndL, .OrL => unreachable, // logical AND and OR have no binary instruction, already handled in TACky
            else => {
                instructions.appendSliceAssumeCapacity(&.{
                    .{ .Mov = .{ .type = srcType, .src = src1, .dst = dst } },
                    .{ .Binary = .{ .type = dstType, .operator = binary.operator, .src = src2, .dst = dst } },
                });
            },
        }
        instructions.shrinkAndFree(allocator, instructions.items.len);
        return try instructions.toOwnedSlice(allocator);
    }
};

pub const Call = struct { identifier: []const u8 };

pub const Cdq = struct { type: Type }; // nX:AX:= sign-extend of AX.

pub const Cmp = struct { type: Type, arg1: Operand, arg2: Operand };

pub const Cvtsi2sd = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssemblySigned(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), d2i: TAC.IntToDouble) Allocator.Error![]Instruction {
        const src = try Operand.fromVal(allocator, staticConstsByValue, d2i.src);
        const dst = try Operand.fromVal(allocator, staticConstsByValue, d2i.dst);
        const t = Type.fromVal(symbols, d2i.src);

        return try allocator.dupe(Instruction, &.{.{ .Cvtsi2sd = .{ .type = t, .src = src, .dst = dst } }});
    }

    fn toAssemblyUnsigned(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), d2i: TAC.UIntToDouble) Allocator.Error![]Instruction {
        const src = try Operand.fromVal(allocator, staticConstsByValue, d2i.src);
        const dst = try Operand.fromVal(allocator, staticConstsByValue, d2i.dst);
        const t = Type.fromVal(symbols, d2i.src);

        switch (t) {
            .Long => {
                return try allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .type = t, .src = src, .dst = .{ .Reg = .ax } } },
                    .{ .Cvtsi2sd = .{ .type = .Quad, .src = .{ .Reg = .ax }, .dst = dst } },
                });
            },
            .Quad => {
                const outOfRangeLabel = try allocator.print("cttsi2sd.out_of_range.{d}", .{counter});
                const endLabel = try allocator.print("cttsi2sd.end.{d}", .{counter});
                counter += 1;

                return try allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                    .{ .JmpCC = .{ .condition = .l, .target = outOfRangeLabel } },
                    .{ .Cvtsi2sd = .{ .type = t, .src = src, .dst = dst } },
                    .{ .Jmp = .{ .target = endLabel } },
                    .{ .Label = .{ .id = outOfRangeLabel } },
                    .{ .Mov = .{ .type = t, .src = src, .dst = .{ .Reg = .ax } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .ax }, .dst = .{ .Reg = .dx } } },
                    .{ .Binary = .{ .type = t, .operator = .SHR, .src = .{ .Imm = 1 }, .dst = .{ .Reg = .dx } } },
                    .{ .Binary = .{ .type = t, .operator = .AndB, .src = .{ .Imm = 1 }, .dst = .{ .Reg = .ax } } },
                    .{ .Binary = .{ .type = t, .operator = .OrB, .src = .{ .Reg = .dx }, .dst = .{ .Reg = .ax } } },
                    .{ .Cvtsi2sd = .{ .type = t, .src = .{ .Reg = .ax }, .dst = dst } },
                    .{ .Binary = .{ .type = .Double, .operator = .Add, .src = dst, .dst = dst } },
                    .{ .Label = .{ .id = endLabel } },
                });
            },
            else => unreachable,
        }
    }
};

pub const Cvttsd2si = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssemblySigned(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), d2i: TAC.DoubleToInt) Allocator.Error![]Instruction {
        const src = try Operand.fromVal(allocator, staticConstsByValue, d2i.src);
        const dst = try Operand.fromVal(allocator, staticConstsByValue, d2i.dst);
        const t = Type.fromVal(symbols, d2i.dst);

        return try allocator.dupe(Instruction, &.{.{ .Cvttsd2si = .{ .type = t, .src = src, .dst = dst } }});
    }

    fn toAssemblyUnsigned(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), d2u: TAC.DoubleToUInt) Allocator.Error![]Instruction {
        const src = try Operand.fromVal(allocator, staticConstsByValue, d2u.src);
        const dst = try Operand.fromVal(allocator, staticConstsByValue, d2u.dst);
        const t = Type.fromVal(symbols, d2u.dst);

        switch (t) {
            .Long => {
                return try allocator.dupe(Instruction, &.{
                    .{ .Cvttsd2si = .{ .type = .Quad, .src = src, .dst = .{ .Reg = .ax } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .ax }, .dst = dst } },
                });
            },
            .Quad => {
                const outOfRangeLabel = try allocator.print("cttsd2si.out_of_range.{d}", .{counter});
                const endLabel = try allocator.print("cttsd2si.end.{d}", .{counter});
                counter += 1;

                try staticConstsByValue.put(@bitCast(UPPER_BOUND_Q), .{
                    .type = .Double,
                    .name = "UPPER_BOUND",
                    .alignment = 8,
                    .initial = .{ .double = UPPER_BOUND_Q },
                });

                return try allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = .Double, .arg1 = .{ .Data = "UPPER_BOUND" }, .arg2 = src } },
                    .{ .JmpCC = .{ .condition = .ae, .target = outOfRangeLabel } },
                    .{ .Cvttsd2si = .{ .type = t, .src = src, .dst = dst } },
                    .{ .Jmp = .{ .target = endLabel } },
                    .{ .Label = .{ .id = outOfRangeLabel } },
                    .{ .Mov = .{ .type = .Double, .src = src, .dst = .{ .Reg = .xmm1 } } },
                    .{ .Binary = .{ .type = .Double, .operator = .Sub, .src = .{ .Data = "UPPER_BOUND" }, .dst = .{ .Reg = .xmm1 } } },
                    .{ .Cvttsd2si = .{ .type = t, .src = .{ .Reg = .xmm1 }, .dst = dst } },
                    .{ .Mov = .{ .type = t, .src = .{ .Imm = UPPER_BOUND_Q }, .dst = .{ .Reg = .dx } } },
                    .{ .Binary = .{ .type = t, .operator = .Add, .src = .{ .Reg = .dx }, .dst = .{ .Reg = .ax } } },
                    .{ .Label = .{ .id = endLabel } },
                });
            },
            else => unreachable,
        }
    }
};

// unsigned division
pub const Div = struct { type: Type, operand: Operand };

// signed division
pub const Idiv = struct { type: Type, operand: Operand };

pub const Jmp = struct {
    target: []const u8,

    fn toAssembly(allocator: Allocator, jmp: TAC.Jump) Allocator.Error![]Instruction {
        return try allocator.dupe(Instruction, &.{.{ .Jmp = .{ .target = jmp.target } }});
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: []const u8,

    fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), jmpInstr: TAC.Instruction) Allocator.Error![]Instruction {
        const arg2, const t, const condition, const target = switch (jmpInstr) {
            .JumpIfZero => |jz| .{
                try Operand.fromVal(allocator, staticConstsByValue, jz.condition),
                Type.fromVal(symbols, jz.condition),
                ConditionCode.e,
                jz.target,
            },
            .JumpIfNotZero => |jnz| .{
                try Operand.fromVal(allocator, staticConstsByValue, jnz.condition),
                Type.fromVal(symbols, jnz.condition),
                ConditionCode.ne,
                jnz.target,
            },
            else => unreachable,
        };

        return try allocator.dupe(Instruction, switch (t) {
            .Double => &double(arg2, t, condition, target),
            .Long, .Quad => &integer(arg2, t, condition, target),
        });
    }

    fn integer(arg2: Operand, t: Type, condition: ConditionCode, target: []const u8) [2]Instruction {
        return .{
            .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
            .{ .JmpCC = .{ .condition = condition, .target = target } },
        };
    }

    fn double(arg2: Operand, t: Type, condition: ConditionCode, target: []const u8) [3]Instruction {
        return .{
            .{ .Binary = .{ .type = t, .operator = .Xor, .src = .{ .Reg = .xmm0 }, .dst = .{ .Reg = .xmm0 } } },
            .{ .Cmp = .{ .type = t, .arg1 = .{ .Reg = .xmm0 }, .arg2 = arg2 } },
            .{ .JmpCC = .{ .condition = condition, .target = target } },
        };
    }
};

pub const Label = struct {
    id: []const u8,

    fn toAssembly(allocator: Allocator, label: TAC.Label) Allocator.Error![]Instruction {
        return try allocator.dupe(Instruction, &.{.{ .Label = .{ .id = label.identifier } }});
    }
};

pub const Mov = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), copy: TAC.Copy) Allocator.Error![]Instruction {
        const src: Operand = try .fromVal(allocator, staticConstsByValue, copy.src);
        const dst: Operand = try .fromVal(allocator, staticConstsByValue, copy.dst);
        const t: Type = dst.getType(symbols).?;

        return try allocator.dupe(Instruction, &.{.{ .Mov = .{ .type = t, .src = src, .dst = dst } }});
    }
};

/// Sign-extended move (cast 4-bytes signed to 8-bytes)
pub const Movsx = struct { type: Type = .Quad, src: Operand, dst: Operand };

/// Zero-extend move (cast 4-bytes unsigned to 8-bytes)
pub const Movzx = struct { type: Type = .Quad, src: Operand, dst: Operand };

pub const Push = struct { type: Type = .Quad, operand: Operand };

pub const Ret = struct {
    type: Type,

    fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), ret: TAC.Return) Allocator.Error![]Instruction {
        const val = try Operand.fromVal(allocator, staticConstsByValue, ret.val);
        const t = Type.fromVal(symbols, ret.val);
        const dst: Operand = switch (t) {
            .Long, .Quad => .{ .Reg = .ax },
            .Double => .{ .Reg = .xmm0 },
        };

        return try allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = t, .src = val, .dst = dst } },
            .{ .Ret = .{ .type = t } },
        });
    }
};

const ConditionCode = enum {
    // zig fmt: off
    e, ne,
    g, ge, l, le, // signed comparisons
    a, ae, b, be, // unsigend/double comparisons
};

pub const SetCC = struct { condition: ConditionCode, operand: Operand };

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    type: Type,
    operator: Operator,
    operand: Operand,

    fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), unary: TAC.Unary) Allocator.Error![]Instruction {
        var instructions = try ArrayList(Instruction).initCapacity(allocator, 8);

        const src = try Operand.fromVal(allocator, staticConstsByValue, unary.src);
        const dst: Operand = .{ .Pseudo = unary.dst.Var };
        const t = Type.fromVal(symbols, unary.src);

        switch (unary.operator) {
            .Not => {
                switch (t) {
                    .Double => {
                        instructions.appendSliceAssumeCapacity(&.{
                            .{ .Binary = .{ .type = .Double, .operator = .Xor, .src = .{ .Reg = .xmm0 }, .dst = .{ .Reg = .xmm0 } } },
                            .{ .Cmp = .{ .type = t, .arg1 = .{ .Reg = .xmm0 }, .arg2 = src } },
                            .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                            .{ .SetCC = .{ .condition = .e, .operand = dst } },
                        });
                    },
                    .Long, .Quad => {
                        instructions.appendSliceAssumeCapacity(&.{
                            .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                            .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                            .{ .SetCC = .{ .condition = .e, .operand = dst } },
                        });
                    }
                }
            },
            .Dec, .Inc => {
                if (t == .Double) {
                    const key: f64 = 1.0;
                    try staticConstsByValue.put(@bitCast(key), .{
                        .type = .Double,
                        .name = "one",
                        .alignment = 8,
                        .initial = .{ .double = key },
                    });
                    if (unary.operator == .Inc) {
                        instructions.appendAssumeCapacity(
                            .{ .Binary = .{ .type = .Double, .operator = .Add, .src = .{ .Data = "one" }, .dst = src } },
                        );
                    } else {
                        instructions.appendAssumeCapacity(
                            .{ .Binary = .{ .type = .Double, .operator = .Sub, .src = .{ .Data = "one" }, .dst = src } },
                        );
                    }
                } else {
                    instructions.appendAssumeCapacity(
                        .{ .Unary = .{ .type = t, .operator = unary.operator, .operand = src } },
                    );
                }
            },
            .Negate, .Complement =>
                if (t == .Double) {
                    const key: f64 = -0.0;
                    try staticConstsByValue.put(@bitCast(key), .{
                        .type = .Double,
                        .name = "negd",
                        .alignment = 16,
                        .initial = .{ .double = key },
                    });
                    instructions.appendSliceAssumeCapacity(&.{
                        .{ .Mov = .{ .type = t, .src = src, .dst = dst} },
                        .{ .Binary = .{ .type = .Double, .operator = .Xor, .src = .{ .Data = "negd" }, .dst = dst } },
                    });
                } else {
                    instructions.appendSliceAssumeCapacity(&.{
                        .{ .Mov = .{ .type = t, .src = src, .dst = dst } },
                        .{ .Unary = .{ .type = t, .operator = unary.operator, .operand = dst } },
                    });
            },
        }
        instructions.shrinkAndFree(allocator, instructions.items.len);
        return try instructions.toOwnedSlice(allocator);
    }
};

pub const FunCallArgs = struct {
    intRegArgs: []const TypedOperand,
    doubleRegArgs: []const TypedOperand,
    stackArgs: []const TypedOperand,

    fn init(allocator: Allocator, params: []TAC.Val, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant)) Allocator.Error!FunCallArgs {
        var intRegArgs: ArrayList(TypedOperand) = .empty;
        var doubleRegArgs: ArrayList(TypedOperand) = .empty;
        var stackArgs: ArrayList(TypedOperand) = .empty;

        for (params) |param| {
            const operand = try Operand.fromVal(allocator, staticConstsByValue, param);
            const t: Type = switch (param) {
                .Constant => switch (param.Constant) {
                    .int, .uint => .Long,
                    .long, .ulong => .Quad,
                    .double => .Double,
                },
                .Var => .fromVar(symbols, param.Var),
            };

            switch (t) {
                .Double => {
                    if (doubleRegArgs.items.len < ARG_FP_REGISTERS.len) {
                        try doubleRegArgs.append(allocator, .{ .type = t, .operand = operand });
                    } else {
                        try stackArgs.append(allocator, .{ .type = t, .operand = operand });
                    }
                },
                .Long, .Quad => {
                    if (intRegArgs.items.len < ARG_INT_REGISTERS.len) {
                        try intRegArgs.append(allocator, .{ .type = t, .operand = operand });
                    } else {
                        try stackArgs.append(allocator, .{ .type = t, .operand = operand });
                    }
                },
            }
        }

        return .{
            .intRegArgs = try intRegArgs.toOwnedSlice(allocator),
            .doubleRegArgs = try doubleRegArgs.toOwnedSlice(allocator),
            .stackArgs = try stackArgs.toOwnedSlice(allocator),
        };
    }
};

fn checkTypes(symbols: Symbol.Table, op1: Operand, op2: Operand) bool {
    const type1 = op1.getType(symbols);
    const type2 = op2.getType(symbols);

    if (type1) |t1| {
        if (type2) |t2| {
            if (t1 != t2) {
                std.log.err("Mismatched types: {any} and {any}\n", .{ t1, t2 });
                return false;
            }
        }
    } else if (type1 == null and type2 == null) {
        std.log.err("Missing types\n", .{});
        std.log.err("  {any}\n", .{op1});
        std.log.err("  {any}\n", .{op2});
        return false;
    }
    return true;
}

fn funCallToAssembly(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), funCall: TAC.FunCall) ![]Instruction {
    var allocatedStack: usize = 0;
    var assembly: ArrayList(Instruction) = .empty;

    const args = try FunCallArgs.init(allocator, funCall.args, symbols, staticConstsByValue);

    const stackAlign = alignStack(args.stackArgs);
    if (stackAlign) |a| {
        try assembly.append(allocator, a);
        allocatedStack += QUADWORD_BYTES;
    }

    const pushToStack = try pushStackArgs(allocator, args.stackArgs);
    try assembly.appendSlice(allocator, pushToStack);
    allocatedStack = pushToStack.len * QUADWORD_BYTES;

    const intRegisters = try moveRegisterArgs(allocator, &ARG_INT_REGISTERS, args.intRegArgs);
    try assembly.appendSlice(allocator, intRegisters);

    const doubleRegisters = try moveRegisterArgs(allocator, &ARG_FP_REGISTERS, args.doubleRegArgs);
    try assembly.appendSlice(allocator, doubleRegisters);

    try assembly.append(allocator, .{ .Call = .{ .identifier = funCall.name } });

    if (allocatedStack > 0) {
        try assembly.append(allocator, .{
            .Binary = .{
                .type = .Quad,
                .operator = .Add,
                .src = .{ .Imm = allocatedStack },
                .dst = .{ .Reg = .sp },
            },
        });
    }

    const dst = funCall.dst.Var;
    const t: Type = .fromVar(symbols, dst);
    const src: Operand = switch (t) {
        .Double => .{ .Reg = .xmm0 },
        .Long, .Quad => .{ .Reg = .ax },
    };
    try assembly.append(allocator, .{ .Mov = .{ .type = t, .src = src, .dst = .{ .Pseudo = dst } } });


    return try assembly.toOwnedSlice(allocator);
}

fn alignStack(stackArgs: []const TypedOperand) ?Instruction {
    // Define and check how much we need to allocate initially to the stack to make sure it's
    // aligned to 16-bytes on function call, per Sys V ABI
    //
        // Check if we have an even or odd number of stack allocations. If odd, we'll need
        // to allocate an additional 8-bytes to make sure the stack is 16-byte aligned
    if (stackArgs.len % 2 != 0) {
        return .{ .Binary = .{
            .type = .Quad,
            .operator = .Sub,
            .src = .{ .Imm = QUADWORD_BYTES },
            .dst = .{ .Reg = .sp },
        } };
    }
    return null;
}

fn pushStackArgs(
    allocator: Allocator,
    stackArgs: []const TypedOperand,
) ![]Instruction {
    var assembly: ArrayList(Instruction) = .empty;

    // This process in reverse of the Sys V ABI, pushing stack arguments (if any) first in their reverse
    // order, and then register arguments (if any) (similar to GCC)
    var i = stackArgs.len;
    while (i > 0) { // Push stack arguments (arguments 6 and on) first in reverse order
        i -= 1;
        const operand: Operand = stackArgs[i].operand;
        if (stackArgs[i].operand == .Imm or stackArgs[i].operand == .Reg or
            stackArgs[i].type == .Double or stackArgs[i].type == .Quad) {
                try assembly.append(allocator, .{ .Push = .{ .operand = operand } });
        } else {
            try assembly.appendSlice(allocator, &.{
                .{ .Mov = .{ .type = .Long, .src = operand, .dst = .{ .Reg = .ax } } },
                .{ .Push = .{ .operand = .{ .Reg = .ax } } },
            });
        }
    }

    return assembly.toOwnedSlice(allocator);
}

fn moveRegisterArgs(
    allocator: Allocator,
    registers: []const Reg,
    registerArgs: []const TypedOperand,
) ![]Instruction {
    var assembly: ArrayList(Instruction) = .empty;

    var i = registerArgs.len;
    while (i > 0) { // Move arguments in corresponding stack registers
        i -= 1;
        const arg = registerArgs[i];
        try assembly.append(allocator,
            .{ .Mov = .{
                .type = arg.type,
                .src = arg.operand,
                .dst = .{ .Reg = registers[i] } }
            }
        );
    }

    return assembly.toOwnedSlice(allocator);
}

fn signExtend(allocator: Allocator, symbols: Symbol.Table, staticConstsByValue: *AutoHashMap(u64, StaticConstant), se: TAC.SignExtend) Allocator.Error![]Instruction {
    const src = try Operand.fromVal(allocator, staticConstsByValue, se.src);
    const dst = try Operand.fromVal(allocator, staticConstsByValue, se.dst);
    const t = Type.fromVal(symbols, se.dst);

    return try allocator.dupe(Instruction, &.{.{ .Movsx = .{ .type = t, .src = src, .dst = dst } }});
}

fn truncate(allocator: Allocator, staticConstsByValue: *AutoHashMap(u64, StaticConstant), tr: TAC.Truncate) Allocator.Error![]Instruction {
    const src = try Operand.fromVal(allocator, staticConstsByValue, tr.src);
    const dst = try Operand.fromVal(allocator, staticConstsByValue, tr.dst);

    return try allocator.dupe(Instruction, &.{.{ .Mov = .{ .type = .Long, .src = src, .dst = dst } }});
}

fn zeroExtend(allocator: Allocator, staticConstsByValue: *AutoHashMap(u64, StaticConstant), ze: TAC.ZeroExtend) Allocator.Error![]Instruction {
    const src = try Operand.fromVal(allocator, staticConstsByValue, ze.src);
    const dst = try Operand.fromVal(allocator, staticConstsByValue, ze.dst);

    if (dst == .Reg) {
        return try allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = .Long, .src = src, .dst = dst } },
        });
    } else {
        return try allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = .Long, .src = src, .dst = .{ .Reg = .r11 } } },
            .{ .Mov = .{ .type = .Quad, .src = .{ .Reg = .r11 }, .dst = dst } },
        });
    }
}
