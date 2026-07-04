// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");

const Assembler = @This();

pub fn codeGen(allocator: Allocator, ast: Parser.AST) Program {
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

    pub fn print(self: Program) void {
        std.debug.print("{any} (\n", .{@TypeOf(self)});
        self.function.print();
        std.debug.print(")\n", .{});
    }
};

const Function = struct {
    allocator: Allocator,
    name: []const u8,
    instructions: []Instruction,

    pub fn init(allocator: Allocator, function: Parser.Function) Function {
        switch (function.body.type) {
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

    pub fn print(self: Function) void {
        std.debug.print("  {any} (\n", .{@TypeOf(self)});
        std.debug.print("    name={s}\n", .{self.name});
        std.debug.print("    instructions=\n", .{});
        for (self.instructions) |instr| {
            instr.print();
        }
        std.debug.print("  )\n", .{});
    }
};

const Instruction = struct {
    const Type = enum {
        Mov,
        Ret,
    };

    type: Type,
    src: ?Operand = null,
    dst: ?Operand = null,

    pub fn Mov(statement: Parser.Statement) Instruction {
        return .{
            .type = .Mov,
            .src = Operand{ .Imm = statement.expr.value },
            .dst = Operand{ .Reg = .EAX }
        };
    }

    pub fn Ret() Instruction {
        return .{ .type = .Ret };
    }

    pub fn print(self: Instruction) void {
        std.debug.print("      {any} (\n", .{@TypeOf(self)});
        std.debug.print("        type={any}\n", .{self.type});
        if (self.src) |src| {
            switch(src) {
                .Imm => std.debug.print("        src=Imm({s})\n", .{src.Imm}),
                .Reg => std.debug.print("        src=Reg({s})\n", .{@tagName(src.Reg)}),
            }
        }
        if (self.dst) |dst| {
            switch(dst) {
                .Imm => std.debug.print("        dst=Imm({s})\n", .{dst.Imm}),
                .Reg => std.debug.print("        dst=Reg({s})\n", .{@tagName(dst.Reg)}),
            }
        }
        std.debug.print("      )\n", .{});
    }
};

const Reg = enum { EAX, };

const OperandType = enum {
    Imm,
    Reg,
};
const Operand = union(OperandType) {
    Imm: []const u8,
    Reg: Reg,
};
