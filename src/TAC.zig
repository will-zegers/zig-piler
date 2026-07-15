const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");

pub const TAC = @This();
pub const IR = Program;

allocator: Allocator,

pub fn init(allocator: Allocator, ast: Parser.AST) IR {
    return .init(allocator, ast);
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, ast: Parser.AST) Program {
        return .{ .allocator = allocator, .function = .init(allocator, ast) };
    }
};

const Function = struct {
    allocator: Allocator,
    identifier: []const u8,
    body: ArrayList(Instruction),

    const Tag = struct {
        ID: []const u8,
        count: usize,
    };

    pub fn init(allocator: Allocator, ast: Parser.AST) Function {
        const function = ast.function;
        var tag: Tag = .{ .ID = function.name, .count = 0 };

        var body: ArrayList(Instruction) = .empty;
        const val = emitTac(allocator, function.body.expr, &tag, &body) catch fatal("", .{});
        body.append(allocator, .{ .Return = .{ .val = val } }) catch fatal("", .{});

        return .{ .allocator = allocator, .identifier = function.name, .body = body };
    }

    pub fn deinit(self: *Function) void {
        defer self.body.deinit(self.allocator);

        for (self.body.items) |item| {
            switch (item) {
                .Unary => |unary| self.allocator.free(unary.dst.name),
                else => {},
            }
        }
    }

    fn emitTac(allocator: Allocator, expr: Parser.Expression, tag: *Tag, body: *std.ArrayList(Instruction)) !Val {
        switch (expr.type) {
            .Constant => return .{ .expr = expr },
            .Unary => {
                const src = try emitTac(allocator, expr.child.?.*, tag, body);
                const dst: Val = .{ .name = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ tag.ID, tag.count }) };
                tag.count += 1;

                const instruction: Instruction = .{ .Unary = .{ .operator = expr.opType.?, .src = src, .dst = dst } };
                try body.append(allocator, instruction);
                return dst;
            },
        }
    }
};

const InstructionTag = enum { Return, Unary };
const Instruction = union(InstructionTag) {
    Return: Return,
    Unary: Unary,
};

const Return = struct {
    val: Val,
};

const Unary = struct {
    operator: Parser.UnaryOperator,
    src: Val,
    dst: Val,
};

const ValTag = enum { expr, name };
const Val = union(ValTag) {
    expr: Parser.Expression,
    name: []u8,
};
