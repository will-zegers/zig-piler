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

    pub fn print(self: Program) void {
        std.debug.print("{any} (\n", .{@TypeOf(self)});
        self.function.print();
        std.debug.print(")\n", .{});
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

    pub fn print(self: Function) void {
        std.debug.print("  {any} (\n", .{@TypeOf(self)});
        std.debug.print("    name={s}\n", .{self.name});
        std.debug.print("    body=\n", .{});
        self.body.print();
        std.debug.print("  )\n", .{});
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
        const expr = Expression.Constant(tokens);
        _ = expect(.Semicolon, tokens);

        return .{ .type = .Return, .expr = expr };
    }

    pub fn print(self: Statement) void {
        std.debug.print("      {any} (\n", .{@TypeOf(self)});
        std.debug.print("        type={any} expr=\n", .{self.type});
        std.debug.print("        expr=\n", .{});
        self.expr.print();
        std.debug.print("      )\n", .{});
    }
};

pub const Expression = struct {
    const Type = enum {
        Constant,
    };

    type: Type,
    value: []const u8,

    pub fn Constant(tokens: *TokenIterator) Expression {
        return .{ .type = .Constant, .value = expect(.Constant, tokens) };
    }

    pub fn print(self: Expression) void {
        std.debug.print("          {any} (\n", .{@TypeOf(self)});
        std.debug.print("            type={any}\n", .{self.type});
        std.debug.print("            value={s})\n", .{self.value});
        std.debug.print("          )\n", .{});
    }
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
