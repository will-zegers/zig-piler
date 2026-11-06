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
    Cttsd2si,
    Cttsi2sd,
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
    Cttsd2si: Cttsd2si,
    Cttsi2sd: Cttsi2sd,
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
    pub fn assemble(allocator: Allocator, symbols: Symbol.Table, instruction: TAC.Instruction) []Instruction {
        return switch (instruction) {
            .Binary => Binary.toAssembly(allocator, symbols, instruction.Binary),
            .Copy => Mov.toAssembly(allocator, symbols, instruction.Copy),
            .DoubleToInt => Cttsd2si.toAssemblySigned(allocator, symbols, instruction.DoubleToInt),
            .DoubleToUInt => Cttsd2si.toAssemblySigned(allocator, symbols, instruction.DoubleToInt),
            .FunCall => funCallToAssembly(allocator, symbols, instruction.FunCall) catch allocError(),
            .IntToDouble => Cttsi2sd.toAssemblySigned(allocator, symbols, instruction.IntToDouble),
            .Jump => Jmp.toAssembly(allocator, instruction.Jump),
            .JumpIfZero, .JumpIfNotZero => JmpCC.toAssembly(allocator, symbols, instruction),
            .Label => Label.toAssembly(allocator, instruction.Label),
            .Return => Ret.toAssembly(allocator, symbols, instruction.Return),
            .SignExtend => signExtend(allocator, symbols, instruction.SignExtend),
            .Truncate => truncate(allocator, instruction.Truncate),
            .UIntToDouble => Cttsi2sd.toAssemblyUnsigned(allocator, symbols, instruction.UIntToDouble),
            .Unary => Unary.toAssembly(allocator, symbols, instruction.Unary),
            .ZeroExtend => zeroExtend(allocator, instruction.ZeroExtend),
        };
    }

    pub fn getType(self: Instruction) ?Type {
        return switch (self) {
            .Binary => self.Binary.type,
            .Cdq => self.Cdq.type,
            .Cmp => self.Cmp.type,
            .Cttsd2si => self.Cttsd2si.type,
            .Cttsi2sd => self.Cttsi2sd.type,
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

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, binary: TAC.Binary) []Instruction {
        const src1: Operand = .fromVal(binary.src1);
        const src2: Operand = .fromVal(binary.src2);
        const dst: Operand = .{ .Pseudo = binary.dst.Var };
        std.debug.assert(assertTypes(symbols, src1, dst));
        std.debug.assert(assertTypes(symbols, src2, dst));

        const signed = symbols.get(binary.dst.Var).?.type.signed();
        const t: Type = .fromVar(symbols, binary.dst.Var);

        return switch (binary.operator) {
            .Div, .Mod => blk: {
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
                    .{ .Mov = .{ .type = t, .src = .{ .Imm = 0 }, .dst = dst } },
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

pub const Cttsd2si = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssemblySigned(allocator: Allocator, symbols: Symbol.Table, d2i: TAC.DoubleToInt) []Instruction {
        const src: Operand = .fromVal(d2i.src);
        const dst: Operand = .fromVal(d2i.dst);
        std.debug.assert(assertTypes(symbols, src, dst));
        const t: Type = .fromVal(symbols, d2i.dst);

        switch (t) {
            .Long => {},
            .Quad => {},
            else => unreachable,
        }

        return allocator.dupe(Instruction, &.{
            .{ .Cttsd2si = .{ .type = t, .src = src, .dst = dst } },
        }) catch allocError();
    }

    fn toAssemblyUnsigned(allocator: Allocator, symbols: Symbol.Table, d2i: TAC.DoubleToUInt) []Instruction {
        const src: Operand = .fromVal(d2i.src);
        const dst: Operand = .fromVal(d2i.dst);
        std.debug.assert(assertTypes(symbols, src, dst));
        const t: Type = .fromVal(symbols, d2i.dst);

        switch (t) {
            .Long => {},
            .Quad => {},
            else => unreachable,
        }

        return allocator.dupe(Instruction, &.{
            .{ .Cttsd2si = .{ .type = t, .src = src, .dst = dst } },
        }) catch allocError();
    }
};

pub const Cttsi2sd = struct {
    type: Type,
    src: Operand,
    dst: Operand,

    fn toAssemblySigned(allocator: Allocator, symbols: Symbol.Table, d2i: TAC.IntToDouble) []Instruction {
        const src: Operand = .fromVal(d2i.src);
        const dst: Operand = .fromVal(d2i.dst);
        std.debug.assert(assertTypes(symbols, src, dst));
        const t: Type = .fromVal(symbols, d2i.dst);

        switch (t) {
            .Long => {},
            .Quad => {},
            else => unreachable,
        }

        return allocator.dupe(Instruction, &.{
            .{ .Cttsd2si = .{ .type = t, .src = src, .dst = dst } },
        }) catch allocError();
    }

    fn toAssemblyUnsigned(allocator: Allocator, symbols: Symbol.Table, d2i: TAC.UIntToDouble) []Instruction {
        const src: Operand = .fromVal(d2i.src);
        const dst: Operand = .fromVal(d2i.dst);
        std.debug.assert(assertTypes(symbols, src, dst));
        const t: Type = .fromVal(symbols, d2i.src);

        switch (t) {
            .Long => {},
            .Quad => {},
            else => unreachable,
        }

        return allocator.dupe(Instruction, &.{
            .{ .Cttsd2si = .{ .type = t, .src = src, .dst = dst } },
        }) catch allocError();
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

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, jmpInstr: TAC.Instruction) []Instruction {
        return switch (jmpInstr) {
            .JumpIfZero => |jz| blk: {
                const arg2: Operand = .fromVal(jz.condition);
                const t: Type = .fromVal(symbols, jz.condition);

                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .e, .target = jz.target } },
                }) catch allocError();
            },
            .JumpIfNotZero => |jnz| blk: {
                const arg2: Operand = .fromVal(jnz.condition);
                const t: Type = .fromVal(symbols, jnz.condition);

                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Imm = 0 }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .ne, .target = jnz.target } },
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
        std.debug.assert(assertTypes(symbols, src, dst));

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

    pub fn toAssembly(allocator: Allocator, symbols: Symbol.Table, ret: TAC.Return) []Instruction {
        const val: Operand = .fromVal(ret.val);
        const t: Type = .fromVal(symbols, ret.val);

        return allocator.dupe(Instruction, &.{
            .{ .Mov = .{ .type = t, .src = val, .dst = .{ .Reg = .ax } } },
            .{ .Ret = .{ .type = t } },
        }) catch allocError();
    }
};

// G, GE, L, LE are condition code for signd comparison; A, AE, B, BE for unsigned
const ConditionCode = enum { e, ne, g, ge, l, le, a, ae, b, be };
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
        const dstType: Type = switch (unary.operator) {
            .Not => .Long, // 'not' always uses 4-byte operands
            else => blk: {
                std.debug.assert(assertTypes(symbols, src, dst));
                break :blk .fromVal(symbols, unary.dst);
            },
        };

        return allocator.dupe(Instruction, switch (unary.operator) {
            .Not => &.{
                .{ .Cmp = .{ .type = srcType, .arg1 = .{ .Imm = 0 }, .arg2 = src } },
                .{ .Mov = .{ .type = dstType, .src = .{ .Imm = 0 }, .dst = dst } },
                .{ .SetCC = .{ .condition = .e, .operand = dst } },
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

    fn constantToImm(constant: TAC.Constant) usize {
        return switch (constant) {
            .double => unreachable,
            .int => @bitCast(@as(isize, constant.int)),
            .long => @intCast(constant.long),
            .uint => @intCast(constant.uint),
            .ulong => @intCast(constant.ulong),
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
    sp,
    mmx0,
    mmx1,
    mmx2,
    mmx3,
    mmx4,
    mmx5,
    mmx6,
    mmx7,
    mmx8,
    mmx9,
    mmx10,
    mmx11,
    mmx12,
    mmx13,
    mmx14,
    mmx15,
};

pub const Type = enum {
    Long,
    Quad,
    Double,

    pub fn fromVar(symbols: Symbol.Table, v: TAC.Var) Type {
        return switch (symbols.get(v).?.type) {
            .Double => .Double,
            .Int, .UInt => .Long,
            .Long, .ULong => .Quad,
            .FunType => unreachable,
        };
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

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}

fn assertTypes(symbols: Symbol.Table, op1: Operand, op2: Operand) bool {
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
    // order, and then register arguments (if any) (similar to GCC)
    var i = funCall.args.len;
    while (i > ARG_REGISTERS.len) { // Push stack arguments (arguments 6 and on) first in reverse order
        i -= 1;
        const operand: Operand = blk: switch (funCall.args[i]) {
            .Constant => .fromVal(funCall.args[i]),
            .Var => |arg| {
                switch (Type.fromVar(symbols, arg)) {
                    .Double => unreachable,
                    .Quad => break :blk .fromVal(funCall.args[i]),
                    .Long => {
                        // For long word vars, first move them into the lower bytes bytes of AX register,
                        // then push rax (quadword register)
                        try assembly.append(allocator, .{ .Mov = .inferType(symbols, .{ .Pseudo = arg }, .{ .Reg = .ax }) });
                        break :blk .{ .Reg = .ax };
                    },
                }
            },
        };
        try assembly.append(allocator, .{ .Push = .{ .operand = operand } });

        allocatedStack += QUADWORD_BYTES;
    }
    while (i > 0) { // Move arguments in corresponding stack registers
        i -= 1;
        const arg = funCall.args[i];
        try assembly.append(allocator, .{
            .Mov = .{
                .type = .fromVal(symbols, arg),
                .src = .fromVal(arg),
                .dst = .{ .Reg = ARG_REGISTERS[i] },
            },
        });
    }

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

fn truncate(allocator: Allocator, tr: TAC.Truncate) []Instruction {
    const src: Operand = .fromVal(tr.src);
    const dst: Operand = .fromVal(tr.dst);

    return allocator.dupe(Instruction, &.{.{ .Mov = .{ .type = .Long, .src = src, .dst = dst } }}) catch allocError();
}

fn zeroExtend(allocator: Allocator, ze: TAC.ZeroExtend) []Instruction {
    const src: Operand = .fromVal(ze.src);
    const dst: Operand = .fromVal(ze.dst);

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
