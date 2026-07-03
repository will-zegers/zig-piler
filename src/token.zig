const std = @import("std");
const mem = std.mem;

pub const TokenType = enum {
    Identifier,
    Constant,
    Keyword,
    OpenParenthesis,
    CloseParenthesis,
    OpenBrace,
    CloseBrace,
    Semicolon,
};

pub const Token = struct {
    const Self = @This();

    type: TokenType,
    value: []const u8,
};

pub const TokenIterator = struct {
    items: []const Token,
    index: usize = 0,

    pub fn next(self: *TokenIterator) ?Token {
        if (self.index < self.items.len) {
            defer self.index += 1;
            return self.items[self.index];
        }
        return null;
    }

    pub fn peek(self: *TokenIterator) ?Token {
        if (self.index < self.items.len) {
            return self.items[self.index];
        }
        return null;
    }
};

const KEYWORDS = [_][]const u8{ "int", "return", "void" };
pub fn getIdentifierType(token: []const u8) TokenType {
    for (KEYWORDS) |keyword| {
        if (mem.eql(u8, keyword, token)) {
            return .Keyword;
        }
    }
    return .Identifier;
}
