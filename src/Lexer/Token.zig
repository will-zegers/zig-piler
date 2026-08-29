const std = @import("std");
const Allocator = std.mem.Allocator;

const Token = @This();

type: Type,
symbol: []const u8,
precedence: usize = 0, // higher number means higher precedence, 0 means no precedence (e.g. for identifiers and constants)
associativity: enum { LeftToRight, RightToLeft, None } = .None,
lineIndex: usize = 0, // used for tracking the line number of the token in the source code for error reporting during parsing

pub const Type = enum {
    BinaryOp,
    Break,
    Case,
    CloseBrace,
    CloseParenthesis,
    Colon,
    Comma,
    Constant,
    Continue,
    Default,
    Do,
    Else,
    For,
    Goto,
    Identifier,
    If,
    Int,
    OpenBrace,
    OpenParenthesis,
    Return,
    Semicolon,
    Switch,
    TernaryOp,
    UnaryOp,
    Void,
    While,
};

pub fn iterate(allocator: Allocator, tokens: []Token) Iterator {
    return .{ .allocator = allocator, .items = tokens };
}

pub const Iterator = struct {
    allocator: Allocator,
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

    pub fn deinit(self: *Iterator) void {
        self.allocator.free(self.items);
    }

    /// Needed for some of the trickier parses. 'count' is the number of
    /// indices to look ahead. So 0 is equivalent to calling 'peek', 1 will
    /// give the token after it without consuming any in betweeen, etc.
    pub fn lookAhead(self: Iterator, count: usize) ?Token {
        if (self.index + count < self.items.len) {
            return self.items[self.index + count];
        }
        return null;
    }

    pub fn peek(self: Iterator) ?Token {
        return self.lookAhead(0);
    }

    pub fn skip(self: *Iterator) void {
        self.index += 1;
    }

    pub fn reset(self: *Iterator) void {
        self.index = 0;
        self.lineIndex = 0;
    }
};
