const std = @import("std");

const Token = @This();

type: Type,
symbol: []const u8,

pub const Type = enum {
    BinaryOp,
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

pub fn iterate(tokens: []Token) Iterator {
    return .{ .items = tokens };
}

pub const Iterator = struct {
    items: []const Token,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Token {
        if (self.index < self.items.len) {
            defer self.index += 1;
            return self.items[self.index];
        }
        return null;
    }

    pub fn peek(self: *Iterator) ?Token {
        if (self.index < self.items.len) {
            return self.items[self.index];
        }
        return null;
    }
};
