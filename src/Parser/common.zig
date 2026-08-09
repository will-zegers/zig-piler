const std = @import("std");

const Token = @import("../Lexer.zig").Token;

pub const identifier = []const u8;
pub const int = []const u8;

pub const ParsingError = error{
    EOF,
    Lvalue,
    Syntax,
    Token,
};

pub fn unexpectedEOF() noreturn {
    std.log.err("Unexpected end of file", .{});
    std.process.exit(1);
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}

pub fn expect(expected: Token.Type, token: ?Token) ParsingError!void {
    if (token == null) {
        std.log.err("Unexpected end of file", .{});
        return ParsingError.Syntax;
    }

    if (expected != token.?.type) {
        std.log.err("Got unexpected {any} token '{s}'. Expected type {any}", .{ token.?.type, token.?.symbol, expected });
        return ParsingError.Syntax;
    }
}
