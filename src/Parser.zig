const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fatal = std.process.fatal;
const ArrayList = std.ArrayList;

const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const expression = @import("Parser/expression.zig");
pub const Expression = expression.Expression;
pub const Binary = expression.Binary;
pub const Unary = expression.Unary;
pub const Factor = expression.Factor;
pub const Constant = expression.Constant;

const Parser = @This();

pub const AST = Program;

const identifier = []const u8;
const int = []const u8;

pub fn parse(allocator: Allocator, tokens: []Token) AST {
    var tokenIter = Token.iterate(tokens);

    const ast = Program.init(allocator, &tokenIter);
    if (tokenIter.next()) |token| {
        fatal("Unexpected token(s) at end of file: {s}", .{token.symbol});
    }

    return ast;
}

pub const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Program {
        return .{ .allocator = allocator, .function = .init(allocator, tokens) };
    }

    pub fn deinit(self: *Program) void {
        self.function.deinit();
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: identifier,
    body: std.ArrayList(BlockItem),

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Function {
        var body: ArrayList(BlockItem) = .empty;

        expect(.Int, tokens.next());

        const name = tokens.next();
        expect(.Identifier, name);

        expect(.OpenParenthesis, tokens.next());
        expect(.Void, tokens.next());
        expect(.CloseParenthesis, tokens.next());

        expect(.OpenBrace, tokens.next());
        while (tokens.peek()) |nextToken| {
            if (.CloseBrace == nextToken.type) break;

            const blockItem = BlockItem.parse(allocator, tokens);
            body.append(allocator, blockItem) catch @panic("OOM");
        }
        expect(.CloseBrace, tokens.next());

        return .{ .allocator = allocator, .name = name.?.symbol, .body = body };
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
                .Declaration => {},
            }
        }
    }
};

pub const BlockItemTag = enum { Declaration, Statement };
pub const BlockItem = union(BlockItemTag) {
    Declaration: Declaration,
    Statement: Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) BlockItem {
        const nextToken = tokens.peek() orelse unexpectedEOF();
        if (.Int == nextToken.type) {
            return .{ .Declaration = Declaration.init(allocator, tokens) };
        }
        return .{ .Statement = Statement.parse(allocator, tokens) };
    }
};

const StatementTag = enum { Expression, Return, Null };
pub const Statement = union(StatementTag) {
    Expression: Expression,
    Return: Return,
    Null: void,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) Statement {
        const nextToken = tokens.peek() orelse unexpectedEOF();
        if (.Return == nextToken.type) {
            return .{ .Return = Return.init(allocator, tokens) };
        } else if (.Semicolon == nextToken.type) {
            _ = tokens.next(); // consome the semicolon token
            return .{ .Null = {} };
        } else {
            return .{ .Expression = Expression.parse(allocator, tokens, 0) };
        }
    }
};

pub const Declaration = struct {
    name: identifier,
    initialize: ?Expression = null,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Declaration {
        expect(.Int, tokens.next());
        const name = tokens.next() orelse unexpectedEOF();
        expect(.Identifier, name);

        var initialize: ?Expression = null;
        if (tokens.peek()) |nextToken| {
            if (mem.eql(u8, "=", nextToken.symbol)) {
                _ = tokens.next(); // discard the assignment operator
                initialize = Expression.parse(allocator, tokens, 0);
            }
        }
        expect(.Semicolon, tokens.next());

        return .{ .name = name.symbol, .initialize = initialize };
    }
};

pub const Return = struct {
    allocator: Allocator,
    expr: Expression,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Return {
        expect(.Return, tokens.next());
        const expr = Expression.parse(allocator, tokens, 0);
        expect(.Semicolon, tokens.next());

        return .{ .allocator = allocator, .expr = expr };
    }

    pub fn deinit(self: *Return) void {
        switch (self.expr) {
            .Factor => switch (self.expr.Factor) {
                .Constant, .Var => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => |*binary| binary.deinit(),
            .Assignment => |*assign| assign.deinit(),
        }
    }
};

fn expect(expected: Token.Type, token: ?Token) void {
    if (token == null) {
        fatal("Unexpected end of file", .{});
    }

    if (expected != token.?.type) {
        fatal("Got unexpected token {s} of type {any}; expected type {any}", .{ token.?.symbol, token.?.type, expected });
    }
}

fn unexpectedEOF() noreturn {
    fatal("Unexpected end of file", .{});
}
