// TODO: break this file up
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const math = std.math;

const Parser = @import("../Parser.zig");
const TAC = @import("../TAC.zig");

const Symbol = @import("../Semantic.zig").Symbol;

pub const InstructionList = ArrayList(Instruction);

var counter: usize = 0;

pub const ARG_INT_REGISTERS = [_]Reg{ .di, .si, .dx, .cx, .r8, .r9 };
pub const ARG_FP_REGISTERS = [_]Reg{
    .xmm0, .xmm1, .xmm2, .xmm3,
    .xmm4, .xmm5, .xmm6, .xmm7,
};
pub const LONGWORD_BYTES: isize = 4;
pub const QUADWORD_BYTES: isize = 8;

pub const StaticVariable = struct {
    type: Type,
    name: []const u8,
    global: bool,
    initial: Symbol.StaticInit,
    alignment: usize,

    pub fn init(tacType: Parser.Type, staticVar: TAC.StaticVariable) StaticVariable {
        const t: Type = .fromTAC(tacType);
        return .{
            .type = t,
            .name = staticVar.identifier,
            .global = staticVar.global,
            .alignment = t.alignment(),
            .initial = staticVar.initial,
        };
    }

    pub fn isZero(self: StaticVariable) bool {
        return switch (self.initial) {
            .double => self.initial.double == 0,
            .int => self.initial.int == 0,
            .uint => self.initial.uint == 0,
            .long => self.initial.long == 0,
            .ulong => self.initial.ulong == 0,
        };
    }
};

pub const StaticConstant = struct {
    type: Type,
    name: []const u8,
    alignment: usize,
    initial: Symbol.StaticInit,

    pub fn init(tacType: Parser.Type, staticConst: TAC.StaticVariable) StaticConstant {
        const t: Type = .fromTAC(tacType);
        return .{
            .type = t,
            .name = staticConst.identifier,
            .initial = staticConst.initial,
            .alignment = t.alignment(),
        };
    }
};
const UPPER_BOUND_Q: f64 = 9223372036854775808.0;

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

    // TODO: see about making this 'toAssembly' funcation non-pub
    pub fn assemble(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), instruction: TAC.Instruction) []Instruction {
        return switch (instruction) {
            .Binary => Binary.toAssembly(allocator, symbols, staticConsts, instruction.Binary),
            .Copy => Mov.toAssembly(allocator, symbols, staticConsts, instruction.Copy),
            .DoubleToInt => Cvttsd2si.toAssemblySigned(allocator, symbols, staticConsts, instruction.DoubleToInt),
            .DoubleToUInt => Cvttsd2si.toAssemblyUnsigned(allocator, symbols, staticConsts, instruction.DoubleToUInt),
            .FunCall => funCallToAssembly(allocator, symbols, staticConsts, instruction.FunCall) catch allocError(),
            .IntToDouble => Cvtsi2sd.toAssemblySigned(allocator, symbols, staticConsts, instruction.IntToDouble),
            .Jump => Jmp.toAssembly(allocator, instruction.Jump),
            .JumpIfZero, .JumpIfNotZero => JmpCC.toAssembly(allocator, symbols, staticConsts, instruction),
            .Label => Label.toAssembly(allocator, instruction.Label),
            .Return => Ret.toAssembly(allocator, symbols, staticConsts, instruction.Return),
            .SignExtend => signExtend(allocator, symbols, staticConsts, instruction.SignExtend),
            .Truncate => truncate(allocator, staticConsts, instruction.Truncate),
            .UIntToDouble => Cvtsi2sd.toAssemblyUnsigned(allocator, symbols, staticConsts, instruction.UIntToDouble),
            .Unary => Unary.toAssembly(allocator, symbols, staticConsts, instruction.Unary),
            .ZeroExtend => zeroExtend(allocator, staticConsts, instruction.ZeroExtend),
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

    type: Type,
    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), binary: TAC.Binary) []Instruction {
        const src1: Operand = .fromVal(allocator, staticConsts, binary.src1);
        const src2: Operand = .fromVal(allocator, staticConsts, binary.src2);
        const dst: Operand = .{ .Pseudo = binary.dst.Var };
        std.debug.assert(checkTypes(symbols, src1, dst));
        std.debug.assert(checkTypes(symbols, src2, dst));

        const signed = symbols.get(binary.dst.Var).?.type.signed();
        const t: Type = .fromVar(symbols, binary.dst.Var);

        return switch (binary.operator) {
            .Div, .Mod => blk: {
                if (t == .Double) {
                    break :blk allocator.dupe(Instruction, &.{
                        .{ .Mov = .{ .type = t, .src = src1, .dst = dst } },
                        .{ .Binary = .{ .type = t, .operator = binary.operator, .src = src2, .dst = dst } },
                    });
                } else {
                    const result: Operand = switch (binary.operator) {
                        .Div => .{ .Reg = .ax },
                        .Mod => .{ .Reg = .dx },
                        else => unreachable,
                    };
                    if (signed) { // sign-extend and issue idiv (signed) instruction
                        break :blk allocator.dupe(Instruction, &.{
                            .{ .Mov = .{ .type = t, .src = src1, .dst = .{ .Reg = .ax } } },
                            .{ .Cdq = .{ .type = t } },
                            .{ .Idiv = .{ .type = t, .operand = src2 } },
                            .{ .Mov = .{ .type = t, .src = result, .dst = dst } },
                        });
                    } else { // zero-extend and issue div (unsigned) instruction
                        break :blk allocator.dupe(Instruction, &.{
                            .{ .Mov = .{ .type = t, .src = src1, .dst = .{ .Reg = .ax } } },
                            .{ .Mov = .{ .type = t, .src = .{ .Imm = 0 }, .dst = .{ .Reg = .dx } } },
                            .{ .Div = .{ .type = t, .operand = src2 } },
                            .{ .Mov = .{ .type = t, .src = result, .dst = dst } },
                        });
                    }
                }
            },
            .Eq, .Gt, .Gte, .Lt, .Lte, .Neq => |op| blk: {
                const cCode: ConditionCode = switch (op) {
                    .Eq => .e,
                    .Gt => if (signed) .g else .a,
                    .Gte => if (signed) .ge else .ae,
                    .Lt => if (signed) .l else .b,
                    .Lte => if (signed) .le else .be,
                    .Neq => .ne,
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = src2, .arg2 = src1 } },
                    .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                    .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                });
            },
            .AndL, .OrL => unreachable, // logical AND and OR have no binary instruction, already handled in TACky
            else => allocator.dupe(Instruction, &.{
                .{ .Mov = .inferType(symbols, src1, dst) },
                .{ .Binary = .{ .type = t, .operator = binary.operator, .src = src2, .dst = dst } },
            }),
        } catch allocError();
    }
};

pub const Call = struct { identifier: []const u8 };

pub const Cdq = struct { type: Type }; // nX:AX:= sign-extend of AX.

pub const Cmp = struct { type: Type, arg1: Operand, arg2: Operand };

pub const Cvtsi2sd = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssemblySigned(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), d2i: TAC.IntToDouble) []Instruction {
        const src: Operand = .fromVal(allocator, staticConsts, d2i.src);
        const dst: Operand = .fromVal(allocator, staticConsts, d2i.dst);
        const t: Type = .fromVal(symbols, d2i.src);

        return allocator.dupe(Instruction, &.{.{ .Cvtsi2sd = .{ .type = t, .src = src, .dst = dst } }}) catch allocError();
    }

    fn toAssemblyUnsigned(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), d2i: TAC.UIntToDouble) []Instruction {
        const src: Operand = .fromVal(allocator, staticConsts, d2i.src);
        const dst: Operand = .fromVal(allocator, staticConsts, d2i.dst);
        const t: Type = .fromVal(symbols, d2i.src);

        switch (t) {
            .Long => {
                return allocator.dupe(Instruction, &.{
                    .{ .Movsx = .{ .type = t, .src = src, .dst = .{ .Reg = .ax } } },
                    .{ .Cvtsi2sd = .{ .type = t, .src = .{ .Reg = .ax }, .dst = dst } },
                }) catch allocError();
            },
            .Quad => {
                const outOfRangeLabel = allocator.print("cttsi2sd.out_of_range.{d}", .{counter}) catch allocError();
                const endLabel = allocator.print("cttsi2sd.end.{d}", .{counter}) catch allocError();
                counter += 1;

                return allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                    .{ .JmpCC = .{ .condition = .l, .target = outOfRangeLabel } },
                    .{ .Cvtsi2sd = .{ .type = t, .src = src, .dst = dst } },
                    .{ .Jmp = .{ .target = endLabel } },
                    .{ .Label = .{ .id = outOfRangeLabel } },
                    .{ .Mov = .{ .type = t, .src = src, .dst = .{ .Reg = .ax } } },
                    .{ .Binary = .{ .type = t, .operator = .SHR, .src = .{ .Reg = .ax }, .dst = .{ .Reg = .ax } } },
                    .{ .Cvtsi2sd = .{ .type = t, .src = .{ .Reg = .ax }, .dst = dst } },
                    .{ .Binary = .{ .type = .Double, .operator = .Add, .src = dst, .dst = dst } },
                    .{ .Label = .{ .id = endLabel } },
                }) catch allocError();
            },
            else => unreachable,
        }
    }
};

pub const Cvttsd2si = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssemblySigned(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), d2i: TAC.DoubleToInt) []Instruction {
        const src: Operand = .fromVal(allocator, staticConsts, d2i.src);
        const dst: Operand = .fromVal(allocator, staticConsts, d2i.dst);
        const t: Type = .fromVal(symbols, d2i.dst);

        return allocator.dupe(Instruction, &.{.{ .Cvttsd2si = .{ .type = t, .src = src, .dst = dst } }}) catch allocError();
    }

    fn toAssemblyUnsigned(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), d2u: TAC.DoubleToUInt) []Instruction {
        const src: Operand = .fromVal(allocator, staticConsts, d2u.src);
        const dst: Operand = .fromVal(allocator, staticConsts, d2u.dst);
        const t: Type = .fromVal(symbols, d2u.dst);

        switch (t) {
            .Long => {
                return allocator.dupe(Instruction, &.{
                    .{ .Cvttsd2si = .{ .type = t, .src = src, .dst = .{ .Reg = .ax } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .ax }, .dst = dst } },
                }) catch allocError();
            },
            .Quad => {
                const outOfRangeLabel = allocator.print("cttsd2si.out_of_range.{d}", .{counter}) catch allocError();
                const endLabel = allocator.print("cttsd2si.end.{d}", .{counter}) catch allocError();
                counter += 1;

                staticConsts.put(@bitCast(UPPER_BOUND_Q), .{
                    .type = .Double,
                    .name = "UPPER_BOUND",
                    .alignment = 8,
                    .initial = .{ .double = UPPER_BOUND_Q },
                }) catch allocError();

                return allocator.dupe(Instruction, &.{
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
                }) catch allocError();
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

    pub fn toAssembly(allocator: Allocator, jmp: TAC.Jump) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Jmp = .{ .target = jmp.target } }}) catch allocError();
    }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: []const u8,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), jmpInstr: TAC.Instruction) []Instruction {
        const arg2, const t, const condition, const target = switch (jmpInstr) {
            .JumpIfZero => |jz| .{
                Operand.fromVal(allocator, staticConsts, jz.condition),
                Type.fromVal(symbols, jz.condition),
                ConditionCode.e,
                jz.target,
            },
            .JumpIfNotZero => |jnz| .{
                Operand.fromVal(allocator, staticConsts, jnz.condition),
                Type.fromVal(symbols, jnz.condition),
                ConditionCode.ne,
                jnz.target,
            },
            else => unreachable,
        };

        return allocator.dupe(Instruction, switch (t) {
            .Double => &double(arg2, t, condition, target),
            .Long, .Quad => &integer(arg2, t, condition, target),
        }) catch allocError();
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

    pub fn toAssembly(allocator: Allocator, label: TAC.Label) []Instruction {
        return allocator.dupe(Instruction, &.{.{ .Label = .{ .id = label.identifier } }}) catch allocError();
    }
};

pub const Mov = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), copy: TAC.Copy) []Instruction {
        const src: Operand = .fromVal(allocator, staticConsts, copy.src);
        const dst: Operand = .fromVal(allocator, staticConsts, copy.dst);

        return allocator.dupe(Instruction, &.{.{ .Mov = .inferType(symbols, src, dst) }}) catch allocError();
    }

    pub fn inferType(symbols: Symbol.Table, src: Operand, dst: Operand) Mov {
        std.debug.assert(checkTypes(symbols, src, dst));

        var t = dst.getType(symbols);
        if (t == null) t = src.getType(symbols);

        std.debug.assert(t != null);
        return .{ .type = t.?, .src = src, .dst = dst };
    }
};

/// Sign-extended move (cast 4-bytes signed to 8-bytes)
pub const Movsx = struct { type: Type = .Quad, src: Operand, dst: Operand };

/// Zero-extend move (cast 4-bytes unsigned to 8-bytes)
pub const Movzx = struct { type: Type = .Quad, src: Operand, dst: Operand };

pub const Push = struct { type: Type = .Quad, operand: Operand };

pub const Ret = struct {
    type: Type,

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), ret: TAC.Return) []Instruction {
        const val: Operand = .fromVal(allocator, staticConsts, ret.val);
        const t: Type = .fromVal(symbols, ret.val);
        const dst: Operand = switch (t) {
            .Long, .Quad => .{ .Reg = .ax },
            .Double => .{ .Reg = .xmm0 },
        };

        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = t, .src = val, .dst = dst } },
            .{ .Ret = .{ .type = t } },
        }) catch allocError();
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

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), unary: TAC.Unary) []Instruction {
        const src: Operand = .fromVal(allocator, staticConsts, unary.src);
        const dst: Operand = .{ .Pseudo = unary.dst.Var };
        const t: Type = .fromVal(symbols, unary.src);

        switch (unary.operator) {
            .Not => {
                switch (t) {
                    .Double => {
                        return allocator.dupe(Instruction, &.{
                            .{ .Binary = .{ .type = .Double, .operator = .Xor, .src = .{ .Reg = .xmm0 }, .dst = .{ .Reg = .xmm0 } } },
                            .{ .Cmp = .{ .type = t, .arg1 = .{ .Reg = .xmm0 }, .arg2 = src } },
                            .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                            .{ .SetCC = .{ .condition = .e, .operand = dst } },
                        }) catch allocError();
                    },
                    .Long, .Quad => {
                        return allocator.dupe(Instruction, &.{
                            .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                            .{ .Mov = .{ .type = .Long, .src = .{ .Imm = 0 }, .dst = dst } },
                            .{ .SetCC = .{ .condition = .e, .operand = dst } },
                        }) catch allocError();
                    }
                }
            },
            .Dec, .Inc => {
                return allocator.dupe(Instruction, &.{
                    .{ .Unary = .{ .type = t, .operator = unary.operator, .operand = src } },
                }) catch allocError();
            },
            .Negate, .Complement =>
                if (t == .Double) {
                    const key: f64 = -0.0;
                    staticConsts.put(@bitCast(key), .{
                        .type = .Double,
                        .name = "notd",
                        .alignment = 16,
                        .initial = .{ .double = key },
                    }) catch allocError();
                    return allocator.dupe(Instruction, &.{
                        .{ .Mov = .{ .type = t, .src = src, .dst = dst} },
                        .{ .Binary = .{ .type = .Double, .operator = .Xor, .src = src, .dst = dst } },
                    }) catch allocError();
                } else {
                    return allocator.dupe(Instruction, &.{
                        .{ .Mov = .inferType(symbols, src, dst) },
                        .{ .Unary = .{ .type = t, .operator = unary.operator, .operand = dst } },
                    }) catch allocError();
            },
        }
    }
};

const OperandTag = enum { Imm, Reg, Pseudo, Stack, Data };
pub const Operand = union(OperandTag) {
    Imm: usize,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,
    Data: []const u8,

    pub fn fromVal(allocator: Allocator, staticConsts: *AutoHashMap(u64, StaticConstant), val: TAC.Val) Operand {
        return switch (val) {
            .Constant => constantToImm(allocator, staticConsts, val.Constant),
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
    }

    fn constantToImm(allocator: Allocator, staticConsts: *AutoHashMap(u64, StaticConstant), constant: TAC.Constant) Operand {
        return switch (constant) {
            .double => getStaticConst(allocator, staticConsts, constant),
            .int => .{ .Imm = @bitCast(@as(isize, constant.int)) },
            .long => .{ .Imm = @intCast(constant.long) },
            .uint => .{ .Imm = @intCast(constant.uint) },
            .ulong => .{ .Imm = @intCast(constant.ulong) },
        };
    }

    fn getStaticConst(allocator: Allocator, staticConsts: *AutoHashMap(u64, StaticConstant), constant: Parser.Constant) Operand {
        // Double types can't serve as keys in AutoHashMap, so we just bit cast it as a usize
        // to preserve it's unique value but make it hashable
        const key: u64 = @bitCast(constant.double);
        if (!staticConsts.contains(key)) {
            const name = allocator.print("C{d}", .{staticConsts.count()}) catch allocError();
            const staticConst: StaticConstant = .{
                .type = .Double,
                .name = name,
                .alignment = 8,
                .initial = constant,
            };
            staticConsts.put(key, staticConst) catch allocError();
        }
        const staticConst = staticConsts.get(key).?;
        return .{ .Data = staticConst.name };
    }

    pub fn getType(self: Operand, symbols: Symbol.Table) ?Type {
        return switch (self) {
            .Data => .fromVar(symbols, self.Data),
            .Pseudo => .fromVar(symbols, self.Pseudo),
            .Imm, .Reg, .Stack => null,
        };
    }
};

pub const TypedOperand = struct {
    type: Type,
    operand: Operand,
};

pub const FunCallArgs = struct {
    intRegArgs: []const TypedOperand,
    doubleRegArgs: []const TypedOperand,
    stackArgs: []const TypedOperand,

    fn init(
        allocator: Allocator,
        params: []TAC.Val,
        symbols: Symbol.Table,
        staticConsts: *AutoHashMap(u64, StaticConstant)
    ) !FunCallArgs {
        var intRegArgs: ArrayList(TypedOperand) = .empty;
        var doubleRegArgs: ArrayList(TypedOperand) = .empty;
        var stackArgs: ArrayList(TypedOperand) = .empty;

        for (params) |param| {
            const operand: Operand = .fromVal(allocator, staticConsts, param);
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

pub const Reg = enum {
    // zig fmt: off
    sp,
    ax, cl, cx, dx,
    di, si,
    r8, r9, r10, r11,
    xmm0, xmm1, xmm2, xmm3,
    xmm4, xmm5, xmm6, xmm7,
    xmm8, xmm9, xmm10, xmm11,
    xmm12, xmm13, xmm14, xmm15,
};

pub const Type = enum {
    Long,
    Quad,
    Double,

    pub fn alignment(self: Type) usize {
        return switch (self) {
            .Long => 4,
            .Double, .Quad => 8,
        };
    }

    pub fn fromTAC(v: Parser.Type) Type {
        return switch (v) {
            .Int, .UInt => .Long,
            .Double, .Long, .ULong => .Quad,
            .FunType => unreachable,
        };
    }

    pub fn fromVar(symbols: Symbol.Table, v: TAC.Var) Type {
        if (symbols.get(v)) |entry| {
            return switch (entry.type) {
                .Double => .Double,
                .Int, .UInt => .Long,
                .Long, .ULong => .Quad,
                .FunType => unreachable,
            };
        } else {
            return .Double;
        }
    }

    pub fn fromConstant(constant: TAC.Constant) Type {
        return switch (constant) {
            .double => .Double,
            .int, .uint => .Long,
            .long, .ulong => .Quad,
        };
    }

    pub fn fromVal(symbols: Symbol.Table, v: TAC.Val) Type {
        return switch (v) {
            .Var => fromVar(symbols, v.Var),
            .Constant => fromConstant(v.Constant),
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

fn funCallToAssembly(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), funCall: TAC.FunCall) ![]Instruction {
    var allocatedStack: usize = 0;
    var assembly: ArrayList(Instruction) = .empty;

    const args = try FunCallArgs.init(allocator, funCall.args, symbols, staticConsts);

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

fn signExtend(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), se: TAC.SignExtend) []Instruction {
    const src: Operand = .fromVal(allocator, staticConsts, se.src);
    const dst: Operand = .fromVal(allocator, staticConsts, se.dst);
    const t: Type = .fromVal(symbols, se.dst);

    return allocator.dupe(Instruction, &.{.{ .Movsx = .{ .type = t, .src = src, .dst = dst } }}) catch allocError();
}

fn truncate(allocator: Allocator, staticConsts: *AutoHashMap(u64, StaticConstant), tr: TAC.Truncate) []Instruction {
    const src: Operand = .fromVal(allocator, staticConsts, tr.src);
    const dst: Operand = .fromVal(allocator, staticConsts, tr.dst);

    return allocator.dupe(Instruction, &.{.{ .Mov = .{ .type = .Long, .src = src, .dst = dst } }}) catch allocError();
}

fn zeroExtend(allocator: Allocator, staticConsts: *AutoHashMap(u64, StaticConstant), ze: TAC.ZeroExtend) []Instruction {
    const src: Operand = .fromVal(allocator, staticConsts, ze.src);
    const dst: Operand = .fromVal(allocator, staticConsts, ze.dst);

    if (dst == .Reg) {
        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = .Long, .src = src, .dst = dst } },
        }) catch allocError();
    } else {
        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = .Long, .src = src, .dst = .{ .Reg = .r11 } } },
            .{ .Mov = .{ .type = .Quad, .src = .{ .Reg = .r11 }, .dst = dst } },
        }) catch allocError();
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
