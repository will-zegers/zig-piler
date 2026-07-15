// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");

const Assembler = @This();

pub const AST = Program;

pub fn codeGen(allocator: Allocator, ast: Parser.AST) AST {
    return .init(allocator, ast);
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, program: Parser.AST) Program {
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
    instructions: []Instruction,

    pub fn init(allocator: Allocator, function: Parser.Function) Function {
        switch (function.body.tag) {
            .Return => return .{
                .allocator = allocator,
                .name = function.name,
                .instructions = allocator.dupe(
                    Instruction,
                    &.{
                        .Mov(function.body),
                        .Ret(),
                    },
                ) catch { unreachable; }
            },
        }
    }

    pub fn deinit(self: *Function) void {
        self.allocator.free(self.instructions);
    }
};

const Instruction = struct {
    pub const Mnemonic = enum { // Weird name, sure. But it fits, and an homage to THAT cyberpunk movie
        movl,
        ret,
    };

    mnemonic: Mnemonic,
    src: ?Operand = null,
    dst: ?Operand = null,

    pub fn Mov(statement: Parser.Statement) Instruction {
        return .{
            .mnemonic = .movl,
            .src = Operand{ .Imm = statement.expr.Constant.int },
            .dst = Operand{ .Reg = .eax }
        };
    }

    pub fn Ret() Instruction {
        return .{ .mnemonic = .ret };
    }
};

const Reg = enum { eax, };

const OperandType = enum {
    Imm,
    Reg,
};
const Operand = union(OperandType) {
    Imm: []const u8,
    Reg: Reg,
};
