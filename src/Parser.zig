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
    const Tag = enum {
        Return,
    };

    allocator: Allocator,
    expr: Expression,
    tag: Tag,

    pub fn Return(allocator: Allocator, tokens: *TokenIterator) Statement {
        _ = expect(.Return, tokens);
        const expr = expressionFactory(allocator, tokens);
        _ = expect(.Semicolon, tokens);

        return .{ .allocator = allocator, .expr = expr, .tag = .Return };
    }

    pub fn deinit(self: *Statement) void {
        switch (self.expr) {
            .Constant => return,
            .Unary => |*expr| expr.deinit(),
        }
    }
};

pub const ExpressionTag = enum {
    Constant,
    Unary,
};
pub const Expression = union(ExpressionTag) {
    Constant: Constant,
    Unary: Unary,
};

pub const Constant = struct {
    int: []const u8,

    pub fn init(int: []const u8) Constant {
        return .{ .int = int };
    }

    pub fn deinit(_: Constant) void {
        return;
    }
};

pub const Unary = struct {
    pub const Operator = enum {
        Complement,
        Negate,
    };

    allocator: Allocator,
    operator: Operator,
    expr: *Expression,

    pub fn init(allocator: Allocator, symbol: []const u8, tokens: *TokenIterator) Unary {
        const expr = allocator.create(Expression) catch fatal("Failed to allocate expr", .{});
        expr.* = expressionFactory(allocator, tokens);
        const operator: Operator = switch (symbol[0]) {
            '~' => .Complement,
            '-' => .Negate,
            else => unreachable,
        };

        return .{ .allocator = allocator, .operator = operator, .expr = expr };
    }

    pub fn deinit(self: *Unary) void {
        switch (self.expr.*) {
            .Unary => |*expr| expr.deinit(),
            else => {},
        }
        defer self.allocator.destroy(self.expr);
    }
};

pub fn expressionFactory(allocator: Allocator, tokens: *TokenIterator) Expression {
    const token = tokens.next() orelse fatal("Unexpected end of file", .{});
    return switch (token.type) {
        .Constant => .{ .Constant = Constant.init(token.value) },
        .UnaryOp => .{ .Unary = Unary.init(allocator, token.value, tokens) },
        .OpenParenthesis => parseParentheses(allocator, tokens),
        else => fatal("Unexpected expression at '{s}'", .{token.value}),
    };
}

fn parseParentheses(allocator: Allocator, tokens: *TokenIterator) Expression {
    const expr = expressionFactory(allocator, tokens);
    _ = expect(.CloseParenthesis, tokens);

    return expr;
}

fn expect(expected: TokenType, tokens: *TokenIterator) []const u8 {
    const actual = tokens.next() orelse {
        fatal("Unexpected end of file", .{});
    };

    if (expected == actual.type) {
        return actual.value;
    }

    fatal("Got unexpected token {s} of type {any}; expected type {any}", .{ actual.value, actual.type, expected });
}
