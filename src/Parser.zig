const std = @import("std");
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

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
    name: []const u8,
    body: Statement,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Function {
        expect(.Int, tokens.next());

        const name = tokens.next();
        expect(.Identifier, name);

        expect(.OpenParenthesis, tokens.next());
        expect(.Void, tokens.next());
        expect(.CloseParenthesis, tokens.next());

        expect(.OpenBrace, tokens.next());
        const body = Statement.Return(allocator, tokens);
        expect(.CloseBrace, tokens.next());

        return .{ .allocator = allocator, .name = name.?.symbol, .body = body };
    }

    pub fn deinit(self: *Function) void {
        self.body.deinit();
    }
};

pub const Statement = struct {
    const Tag = enum {
        Return,
    };

    allocator: Allocator,
    expr: Expression,
    tag: Tag,

    pub fn Return(allocator: Allocator, tokens: *TokenIterator) Statement {
        expect(.Return, tokens.next());
        const expr = Expression.parse(allocator, tokens, 0);
        expect(.Semicolon, tokens.next());

        return .{ .allocator = allocator, .expr = expr, .tag = .Return };
    }

    pub fn deinit(self: *Statement) void {
        switch (self.expr) {
            .Factor => switch (self.expr.Factor) {
                .Constant => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => |*binary| binary.deinit(),
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
