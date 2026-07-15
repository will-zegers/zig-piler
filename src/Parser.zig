const std = @import("std");
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const tok = @import("token.zig");
const Token = tok.Token;
const TokenIterator = tok.TokenIterator;
const TokenType = tok.TokenType;

const Parser = @This();

pub const AST = Program;

pub fn parse(allocator: Allocator, tokens: []Token) AST {
    var tokenIter = tok.iterate(tokens);

    const ast = Program.init(allocator, &tokenIter);
    if (tokenIter.next()) |token| {
        fatal("Unexpected token(s) at end of file: {s}", .{token.value});
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
        _ = expect(.Int, tokens);
        const name = expect(.Identifier, tokens);
        _ = expect(.OpenParenthesis, tokens);
        _ = expect(.Void, tokens);
        _ = expect(.CloseParenthesis, tokens);
        _ = expect(.OpenBrace, tokens);
        const body = Statement.Return(allocator, tokens);
        _ = expect(.CloseBrace, tokens);

        return .{ .allocator = allocator, .name = name, .body = body };
    }

    pub fn deinit(self: *Function) void {
        self.body.deinit();
    }
};

pub const Statement = struct {
    const Type = enum {
        Return,
    };

    allocator: Allocator,
    type: Type,
    expr: Expression,

    pub fn Return(allocator: Allocator, tokens: *TokenIterator) Statement {
        _ = expect(.Return, tokens);
        const expr = Expression.init(allocator, tokens);
        _ = expect(.Semicolon, tokens);

        return .{ .allocator = allocator, .type = .Return, .expr = expr };
    }

    pub fn deinit(self: *Statement) void {
        self.expr.deinit();
    }
};

pub const Expression = struct {
    const Type = enum {
        Constant,
        Unary,
    };

    allocator: std.mem.Allocator,
    type: Type,
    value: ?[]const u8 = null,
    opType: ?UnaryOperator = null,
    child: ?*Expression = null,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Expression {
        if (tokens.next()) |token| {
            switch (token.type) {
                .Constant => return _Constant(allocator, token.value),
                .UnaryOp => return _Unary(allocator, token, tokens),
                .OpenParenthesis => {
                    const expr = init(allocator, tokens);
                    _ = expect(.CloseParenthesis, tokens);
                    return expr;
                },
                else => fatal("Unexpected expression at {s}", .{token.value}),
            }
        }

        fatal("Unexpected end of file", .{});
    }

    pub fn deinit(self: *Expression) void {
        if (self.child) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
    }

    fn _Constant(allocator: Allocator, value: []const u8) Expression {
        return .{ .allocator = allocator, .type = .Constant, .value = value };
    }

    fn _Unary(allocator: Allocator, token: Token, tokens: *TokenIterator) Expression {
        const expr = allocator.create(Expression) catch fatal("Failed to create child expr for token '{}'", .{token});
        expr.* = init(allocator, tokens);

        const opType: UnaryOperator = switch (token.value[0]) {
            '~' => .Complement,
            '-' => .Negate,
            else => unreachable,
        };

        return .{ .allocator = allocator, .type = .Unary, .child = expr, .opType = opType };
    }
};

pub const UnaryOperator = enum {
    Complement,
    Negate,
};

fn expect(expected: TokenType, tokens: *TokenIterator) []const u8 {
    const actual = tokens.next() orelse {
        fatal("Unexpected end of file", .{});
    };

    if (expected == actual.type) {
        return actual.value;
    }

    fatal("Got unexpected token {s} of type {any}; expected type {any}", .{ actual.value, actual.type, expected });
}
