const std = @import("std");
const fatal = std.process.fatal;

const tok = @import("token.zig");
const Token = tok.Token;
const TokenIterator = tok.TokenIterator;
const TokenType = tok.TokenType;

const Parser = @This();

pub const AST = Program;

pub fn parse(tokens: []Token) AST {
    var tokenIter = tok.iterate(tokens);

    const ast = Program.init(&tokenIter);
    if (tokenIter.next()) |token| {
        fatal("Unexpected token(s) at end of file: {s}", .{token.value});
    }

    return ast;
}

pub const Program = struct {
    function: Function,

    pub fn init(tokens: *TokenIterator) Program {
        return .{ .function = .init(tokens) };
    }
};

pub const Function = struct {
    name: []const u8,
    body: Statement,

    pub fn init(tokens: *TokenIterator) Function {
        _ = expect(.Int, tokens);
        const name = expect(.Identifier, tokens);
        _ = expect(.OpenParenthesis, tokens);
        _ = expect(.Void, tokens);
        _ = expect(.CloseParenthesis, tokens);
        _ = expect(.OpenBrace, tokens);
        const body = Statement.Return(tokens);
        _ = expect(.CloseBrace, tokens);

        return .{ .name = name, .body = body };
    }
};

pub const Statement = struct {
    const Type = enum {
        Return,
    };

    type: Type,
    expr: Expression,

    pub fn Return(tokens: *TokenIterator) Statement {
        _ = expect(.Return, tokens);
        const expr = Expression.init(tokens);
        _ = expect(.Semicolon, tokens);

        return .{ .type = .Return, .expr = expr };
    }
};

pub const Expression = struct {
    const Type = enum {
        Constant,
        UnaryOperator,
    };

    allocator: ?std.mem.Allocator = null,
    type: Type,
    value: ?[]const u8 = null,
    opType: ?UnaryOperator = null,
    child: ?*Expression = null,

    pub fn init(tokens: *TokenIterator) Expression {
        if (tokens.next()) |token| {
            switch (token.type) {
                .Constant => return Constant(token.value),
                .UnaryOp => return Unary(token, tokens),
                .OpenParenthesis => {
                    const expr = init(tokens);
                    _ = expect(.CloseParenthesis, tokens);
                    return expr;
                },
                else => fatal("Unexpected expression at {s}", .{token.value}),
            }
        }

        fatal("Unexpected end of file", .{});
    }

    fn Constant(value: []const u8) Expression {
        return .{ .type = .Constant, .value = value };
    }

    pub fn Unary(token: Token, tokens: *TokenIterator) Expression {
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        const allocator = gpa.allocator();

        const expr = allocator.create(Expression) catch fatal("Failed to create child expr for token '{}'", .{token});
        expr.* = init(tokens);

        const opType: UnaryOperator = switch (token.value[0]) {
            '~' => .Complement,
            '-' => .Negate,
            else => unreachable,
        };

        return .{ .allocator = allocator, .type = .UnaryOperator, .child = expr, .opType = opType };
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
