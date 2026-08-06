const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fatal = std.process.fatal;
const ArrayList = std.ArrayList;

const expression = @import("Parser/expression.zig");
pub const Expression = expression.Expression;
pub const Binary = expression.Binary;
pub const Unary = expression.Unary;
pub const Factor = expression.Factor;
pub const Constant = expression.Constant;
pub const Assignment = expression.Assignment;
pub const ParsingError = expression.ParsingError;

const Semantic = @import("Semantic.zig");
const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const Parser = @This();

pub const AST = Program;

const identifier = []const u8;
const int = []const u8;

pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!AST {
    const ast = try Program.init(allocator, tokens);
    if (tokens.peek()) |token| {
        fatal("Unexpected token(s) at end of file: {s}", .{token.symbol});
    }

    return ast;
}

pub const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Program {
        return .{ .allocator = allocator, .function = try .init(allocator, tokens) };
    }

    pub fn deinit(self: *Program) void {
        std.debug.print("deinit called\n", .{});
        self.function.deinit();
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: identifier,
    body: std.ArrayList(BlockItem),

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Function {
        var body: ArrayList(BlockItem) = .empty;

        try expect(.Int, tokens.next());

        const token = tokens.next() orelse unexpectedEOF();
        try expect(.Identifier, token);

        try expect(.OpenParenthesis, tokens.next());
        try expect(.Void, tokens.next());
        try expect(.CloseParenthesis, tokens.next());

        try expect(.OpenBrace, tokens.next());
        while (tokens.peek()) |nextToken| {
            if (.CloseBrace == nextToken.type) break;

            const blockItem = try BlockItem.parse(allocator, tokens);
            body.append(allocator, blockItem) catch allocError();
        }
        try expect(.CloseBrace, tokens.next());

        return .{ .allocator = allocator, .name = token.symbol, .body = body };
    }

    pub fn deinit(self: *Function) void {
        defer self.body.deinit(self.allocator);

        for (self.body.items) |*blockItem| {
            switch (blockItem.*) {
                .Statement => |*statement| {
                    switch (statement.*) {
                        .Return => |*ret| ret.deinit(),
                        .Expression => |*expr| Expression.deinit(expr),
                        .Null => {},
                    }
                },
                .Declaration => |*decl| {
                    if (decl.initialize) |*initExpr| {
                        Expression.deinit(initExpr);
                    }
                },
            }
        }
    }
};

pub const BlockItemTag = enum { Declaration, Statement };
pub const BlockItem = union(BlockItemTag) {
    Declaration: Declaration,
    Statement: Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!BlockItem {
        const nextToken = tokens.peek() orelse unexpectedEOF();
        return if (.Int == nextToken.type)
            .{ .Declaration = try .init(allocator, tokens) }
        else
            .{ .Statement = try .parse(allocator, tokens) };
    }
};

const StatementTag = enum { Expression, Return, Null };
pub const Statement = union(StatementTag) {
    Expression: Expression,
    Return: Return,
    Null: void, // needed to represent empty semicolon statements (for later?)

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Statement {
        const nextToken = tokens.peek() orelse unexpectedEOF();
        return switch (nextToken.type) {
            .Return => .{ .Return = try .init(allocator, tokens) },
            .Semicolon => .{ .Null = tokens.skip() },
            else => .{ .Expression = try .parse(allocator, tokens, 0) },
        };
    }
};

pub const Declaration = struct {
    name: identifier,
    initialize: ?Expression,
    lineIndex: usize,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Declaration {
        try expect(.Int, tokens.next());
        const token = tokens.peek() orelse unexpectedEOF();
        try expect(.Identifier, token);

        const initialize = try Assignment.parse(allocator, tokens);
        try expect(.Semicolon, tokens.next());

        return .{ .name = token.symbol, .initialize = initialize, .lineIndex = token.lineIndex };
    }
};

pub const Return = struct {
    allocator: Allocator,
    expr: Expression,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Return {
        try expect(.Return, tokens.next());
        const expr = try Expression.parse(allocator, tokens, 0);
        try expect(.Semicolon, tokens.next());

        return .{ .allocator = allocator, .expr = expr };
    }

    pub fn deinit(self: *Return) void {
        Expression.deinit(&self.expr);
    }
};

fn expect(expected: Token.Type, token: ?Token) ParsingError!void {
    if (token == null) {
        std.log.err("Unexpected end of file", .{});
        return ParsingError.Syntax;
    }

    if (expected != token.?.type) {
        std.log.err("Got unexpected {any} token '{s}'. Expected type {any}", .{ token.?.type, token.?.symbol, expected });
        return ParsingError.Syntax;
    }
}

fn unexpectedEOF() noreturn {
    std.log.err("Unexpected end of file", .{});
    std.process.exit(1);
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
