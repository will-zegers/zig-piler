const std = @import("std");
const mem = std.mem;
const StaticStringMap = std.StaticStringMap;

pub const TokenType = enum {
    CloseBrace,
    CloseParenthesis,
    Constant,
    Identifier,
    Int,
    OpenBrace,
    OpenParenthesis,
    Return,
    Semicolon,
    UnaryOp,
    Void,
};

pub const KeywordMap = StaticStringMap(TokenType).initComptime(.{
    .{ "int", .Int },
    .{ "return", .Return },
    .{ "void", .Void },
});

pub const Token = struct {
    const Self = @This();

    type: TokenType,
    value: []const u8,
};

pub fn iterate(tokens: []Token) TokenIterator {
    return .{ .items = tokens };
}

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
