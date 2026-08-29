const std = @import("std");

const Token = @import("../Lexer.zig").Token;

pub const identifier = []const u8;
pub const int = []const u8;

// TODO: merge parsing and semantic errors
pub const ParsingError = error{
    DuplicateCase,
    EOF,
    Lvalue,
    NonConstExpr,
    Syntax,
    Token,
};

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}

pub fn expect(expected: Token.Type, token: Token) ParsingError!void {
    if (expected != token.type) {
        std.log.err("Got unexpected {any} token '{s}'. Expected type {any}", .{ token.type, token.symbol, expected });
        return ParsingError.Syntax;
    }
}
