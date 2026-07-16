// zig fmt: off
const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const TAC = @import("TAC.zig");

const Assembler = @This();

pub const AST = Program;

pub fn codeGen(allocator: Allocator, ast: TAC.IR) AST {
    return .init(allocator, ast);
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, program: TAC.IR) Program {
        return .{
            .allocator = allocator,
            .function = Function.init(allocator, program.function)
        };
    }

    pub fn deinit(self: *Program) void {
        self.function.deinit();
    }
};

const Function = struct {
    allocator: Allocator,
    name: []const u8,
    instructions: ArrayList(Instruction),

    pub fn init(allocator: Allocator, function: TAC.Function) Function {
        var instructions: ArrayList(Instruction) = .empty;

        for (function.body.items) |instr| {
            switch (instr) {
                .Unary => |unary| Unary.append(allocator, &instructions, unary),
                .Return => |ret| Ret.append(allocator, &instructions, ret),
            }
        }
        _ = assignStackVars(allocator, &instructions);
        return .{ .allocator = allocator, .name = function.name, .instructions = instructions, };
    }

    pub fn assignStackVars(allocator: Allocator, instructions: *ArrayList(Instruction)) isize {
        var pseudoMap: std.StringHashMap(isize) = .init(allocator);
        defer pseudoMap.deinit();
        var stackCounter: isize = -4;

        for (instructions.items) |*instruction| {
            switch (instruction.*) {
                .Mov => |*mov| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &mov.src);
                    replaceIfPseudo(&pseudoMap, &stackCounter, &mov.dst);
                },
                .Unary => |*unary| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &unary.operand);
                },
                else => {},
            }
        }
        return stackCounter;
    }

    fn replaceIfPseudo(map: *std.StringHashMap(isize), stackCounter: *isize, operand: *Operand) void {
        if (operand.*.isPseudo()) {
            const key = operand.*.Pseudo;
            if (map.get(key) == null) {
                map.put(key, stackCounter.*) catch std.process.exit(1);
                stackCounter.* -= 4;
            }
            const value = map.get(key).?;
            operand.* = .{ .Stack = value };
        }
    }

    pub fn deinit(self: *Function) void {
        defer self.instructions.deinit(self.allocator);
    }
};

const InstructionTag = enum {
    Mov,
    Ret,
    Unary,
    AllocStack,
};
const Instruction = union(InstructionTag) {
    Mov: Mov,
    Ret: Ret,
    Unary: Unary,
    AllocStack: AllocStack,
};

pub const Mov = struct {
    src: Operand,
    dst: Operand,
};

pub const Ret = struct {
    pub fn append(allocator: Allocator, instructions: *ArrayList(Instruction), ret: TAC.Return) void {
        const val: Operand = switch(ret.val) {
            .Constant => |constant| .{ .Imm = constant.int },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };

        instructions.appendSlice(
            allocator,
            &.{
                .{ .Mov = .{.src = val, .dst = .{ .Reg = .AX } } },
                .{ .Ret = .{} },
            },
        ) catch std.process.exit(1);
    }
};

pub const Unary = struct {
    operator: Parser.Unary.Operator,
    operand: Operand,

    pub fn append(allocator: Allocator, instructions: *ArrayList(Instruction), unary: TAC.Unary) void {
        const src: Operand = switch(unary.src) {
            .Constant => |constant| .{ .Imm = constant.int },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        const dst: Operand = .{ .Pseudo = unary.dst.Var };

        instructions.appendSlice(
            allocator, 
            &.{
                .{ .Mov = .{.src = src, .dst = .{ .Pseudo = unary.dst.Var } } },
                .{ .Unary = .{.operator = unary.operator, .operand = dst } },
            },
        ) catch std.process.exit(0);
    }
};

pub const AllocStack = struct {};

const OperandType = enum {
    Imm,
    Reg,
    Pseudo,
    Stack,
};
const Operand = union(OperandType) {
    Imm: []const u8,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,

    pub fn isPseudo(self: Operand) bool {
        return self == Operand.Pseudo;
    }
};

const Reg = enum { AX, R10};

