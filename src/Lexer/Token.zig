const std = @import("std");

const Token = @This();

type: Type,
symbol: []const u8,
precedence: usize = 0, // higher number means higher precedence, 0 means no precedence (e.g. for identifiers and constants)
associativity: enum { LeftToRight, RightToLeft, None } = .None,
lineIndex: usize = 0, // used for tracking the line number of the token in the source code for error reporting during parsing

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
    lineIndex: usize = 0,
    items: []const Token,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Token {
        if (self.index < self.items.len) {
            const token = self.items[self.index];

            self.index += 1;
            self.lineIndex = token.lineIndex;

            return token;
        }
        return null;
    }

    pub fn peek(self: *Iterator) ?Token {
        if (self.index < self.items.len) {
            return self.items[self.index];
        }
        return null;
    }

    pub fn skip(self: *Iterator) void {
        self.index += 1;
    }

    pub fn reset(self: *Iterator) void {
        self.index = 0;
        self.lineIndex = 0;
    }
};
