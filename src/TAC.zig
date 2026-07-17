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

pub const Function = struct {
    allocator: Allocator,
    name: []const u8,
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

        return .{ .allocator = allocator, .name = function.name, .body = body };
    }

    pub fn deinit(self: *Function) void {
        defer self.body.deinit(self.allocator);

        for (self.body.items) |item| {
            switch (item) {
                .Unary => self.allocator.free(item.Unary.dst.Var),
                .Binary => self.allocator.free(item.Binary.dst.Var),
                else => {},
            }
        }
    }

    fn emitTac(allocator: Allocator, expr: Parser.Expression, tag: *Tag, body: *std.ArrayList(Instruction)) !Val {
        switch (expr) {
            .Factor => |factor| switch (factor) {
                .Constant => return .{ .Constant = factor.Constant },
                .Unary => |unary| {
                    const unaryExpr: Parser.Expression = .{ .Factor = unary.factor.* };
                    const src = try emitTac(allocator, unaryExpr, tag, body);
                    const dst: Val = .{ .Var = try nextTag(allocator, tag) };
                    try body.append(allocator, .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = dst } });
                    return dst;
                },
                .Parantheses => |parantheses| {
                    return try emitTac(allocator, parantheses.expr.*, tag, body);
                },
            },
            .Binary => |binary| {
                const left = try emitTac(allocator, binary.left.*, tag, body);
                const right = try emitTac(allocator, binary.right.*, tag, body);
                const dst: Val = .{ .Var = try nextTag(allocator, tag) };
                try body.append(allocator, .{ .Binary = .{ .operator = binary.operator, .left = left, .right = right, .dst = dst } });
                return dst;
            },
        }
    }

    fn nextTag(allocator: Allocator, tag: *Tag) ![]u8 {
        defer tag.count += 1;
        return try std.fmt.allocPrint(allocator, "{s}.{d}", .{ tag.ID, tag.count });
    }
};

const InstructionTag = enum { Binary, Return, Unary };
const Instruction = union(InstructionTag) {
    Binary: Binary,
    Return: Return,
    Unary: Unary,
};

pub const Return = struct {
    val: Val,
};

pub const Unary = struct {
    operator: Parser.Unary.Operator,
    src: Val,
    dst: Val,
};

pub const Binary = struct {
    operator: Parser.Binary.Operator,
    left: Val,
    right: Val,
    dst: Val,
};

const ValTag = enum { Constant, Var };
const Val = union(ValTag) {
    Constant: Constant,
    Var: Var,
};

const Constant = Parser.Constant;
const Var = []u8;
