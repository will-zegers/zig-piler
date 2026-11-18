const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;

const Parser = @import("../Parser.zig");
const Symbol = @import("../Semantic.zig").Symbol;
const TAC = @import("../TAC.zig");

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

    fn init(tacType: Parser.Type, staticConst: TAC.StaticVariable) StaticConstant {
        const t: Type = .fromTAC(tacType);
        return .{
            .type = t,
            .name = staticConst.identifier,
            .initial = staticConst.initial,
            .alignment = t.alignment(),
        };
    }
};

const OperandTag = enum { Imm, Reg, Pseudo, Stack, Data };
pub const Operand = union(OperandTag) {
    Imm: usize,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,
    Data: []const u8,

    pub fn fromVal(allocator: Allocator, staticConstsByValue: *AutoHashMap(u64, StaticConstant), val: TAC.Val) Allocator.Error!Operand {
        return switch (val) {
            .Constant => try constantToImm(allocator, staticConstsByValue, val.Constant),
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };
    }

    fn constantToImm(allocator: Allocator, staticConstsByValue: *AutoHashMap(u64, StaticConstant), constant: TAC.Constant) Allocator.Error!Operand {
        return switch (constant) {
            .double => getStaticConst(allocator, staticConstsByValue, constant),
            .int => .{ .Imm = @bitCast(@as(isize, constant.int)) },
            .long => .{ .Imm = @intCast(constant.long) },
            .uint => .{ .Imm = @intCast(constant.uint) },
            .ulong => .{ .Imm = @intCast(constant.ulong) },
        };
    }

    fn getStaticConst(allocator: Allocator, staticConstsByValue: *AutoHashMap(u64, StaticConstant), constant: Parser.Constant) Allocator.Error!Operand {
        // Double types can't serve as keys in AutoHashMap, so we just bit cast it as a usize
        // to preserve it's unique value but make it hashable
        const key: u64 = @bitCast(constant.double);
        if (!staticConstsByValue.contains(key)) {
            const name = try allocator.print("C{d}", .{staticConstsByValue.count()});
            const staticConst: StaticConstant = .{
                .type = .Double,
                .name = name,
                .alignment = 8,
                .initial = constant,
            };
            try staticConstsByValue.put(key, staticConst);
        }
        const staticConst = staticConstsByValue.get(key).?;
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

    pub fn fromVar(symbols: Symbol.Table, v: TAC.Var) Type {
        if (symbols.get(v)) |entry| {
            return switch (entry.type) {
                .Double => .Double,
                .Int, .UInt => .Long,
                .Long, .ULong => .Quad,
                .FunType, .Pointer => unreachable,
            };
        } else {
            return .Double;
        }
    }

    fn alignment(self: Type) usize {
        return switch (self) {
            .Long => 4,
            .Double, .Quad => 8,
        };
    }

    fn fromTAC(v: Parser.Type) Type {
        return switch (v) {
            .Int, .UInt => .Long,
            .Double, .Long, .ULong => .Quad,
            .FunType, .Pointer => unreachable,
        };
    }

    fn fromConstant(constant: TAC.Constant) Type {
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

