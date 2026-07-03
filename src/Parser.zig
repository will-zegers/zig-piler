const std = @import("std");
const fatal = std.process.fatal;

const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const TokenIterator = token.TokenIterator;

pub const Parser = struct {
    const Self = @This();

    program: Program,

    pub fn parse(tokens: *TokenIterator) Self {
        const program: Program = .parse(tokens);
        if (tokens.peek()) |t| {
            fatal("Unexpected token '{s}' at end of file", .{t.value});
        }
        return .{ .program = program };
    }

    pub fn print(self: Self) !void {
        try self.program.print();
    }
};

const Expression = struct {
    const Self = @This();

    value: []const u8,
    type: TokenType,

    pub fn parse(tokens: *TokenIterator) Self {
        const tok = expect(.Constant, tokens);
        _ = expect(.Semicolon, tokens);
        return .{
            .value = tok.value,
            .type = tok.type,
        };
    }

    pub fn print(self: Self) void {
        std.log.info("∙∙∙∙∙∙∙∙∙∙Expression (", .{});
        std.log.info("∙∙∙∙∙∙∙∙∙∙∙∙{s} ({any})", .{ self.value, self.type });
        std.log.info("∙∙∙∙∙∙∙∙∙∙)", .{});
    }
};

const Body = struct {
    const Self = @This();

    token_: Token,
    expression: Expression,

    pub fn parse(tokens: *TokenIterator) Self {
        const token_ = expect(.Keyword, tokens);
        const expression: Expression = .parse(tokens);
        return .{
            .token_ = token_,
            .expression = expression,
        };
    }

    pub fn print(self: Self) void {
        std.log.info("∙∙∙∙∙∙Body (", .{});
        std.log.info("∙∙∙∙∙∙∙∙keyword = {s} ({any})", .{ self.token_.value, self.token_.type });
        std.log.info("∙∙∙∙∙∙∙∙expression = ", .{});
        self.expression.print();
        std.log.info("∙∙∙∙∙∙)", .{});
    }
};

const Function = struct {
    const Self = @This();

    returnType: []const u8,
    name: []const u8,
    args: []const u8,
    body: Body,

    pub fn parse(tokens: *TokenIterator) Self {
        const returnType = expect(.Keyword, tokens).value;
        const name = expect(.Identifier, tokens).value;
        _ = expect(.OpenParenthesis, tokens);
        const args = expect(.Keyword, tokens).value;
        _ = expect(.CloseParenthesis, tokens);
        _ = expect(.OpenBrace, tokens);
        const body = Body.parse(tokens);
        _ = expect(.CloseBrace, tokens);
        return .{
            .returnType = returnType,
            .name = name,
            .args = args,
            .body = body,
        };
    }

    pub fn print(self: Self) void {
        std.log.info("∙∙Function (", .{});
        std.log.info("∙∙∙∙name = {s}", .{self.name});
        std.log.info("∙∙∙∙body = ", .{});
        self.body.print();
        std.log.info("∙∙)", .{});
    }
};

const Program = struct {
    const Self = @This();

    function: Function,

    pub fn parse(tokens: *TokenIterator) Self {
        return .{ .function = .parse(tokens) };
    }

    pub fn print(self: Self) !void {
        std.log.info("Program (", .{});
        self.function.print();
        std.log.info(")", .{});
    }
};

fn expect(expected: TokenType, tokens: *TokenIterator) Token {
    const actual = tokens.next() orelse {
        fatal("End of file reached. Expected {any}", .{expected});
    };

    if (expected == actual.type) {
        return actual;
    }

    switch (actual.type) {
        .Identifier => switch (expected) {
            .Keyword => fatal("{s} does not name a type", .{actual.value}),
            else => fatal("Undeclared identifer {s}", .{actual.value}),
        },
        .Keyword => fatal("Unexpected keyword use {s}", .{actual.value}),
        .Constant => fatal("Exted identifier or keyword, got {s}", .{actual.value}),
        else => switch (expected) {
            .Semicolon => fatal("Missing semicolon before {s}\n", .{actual.value}),
            else => fatal("Unexpected token {s}\n", .{actual.value}),
        },
    }
}
