const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Regex = @import("Lexer/Regex.zig");
const StringHashMap = std.StringHashMap;

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

const Token = struct {
    type: TokenType,
    value: []const u8,
};

const KEYWORDS = [_][]const u8{ "int", "return", "void" };
fn getIdentifierType(token: []const u8) TokenType {
    for (KEYWORDS) |keyword| {
        if (mem.eql(u8, keyword, token)) {
            return .Keyword;
        }
    }
    return .Identifier;
}

const Lexer = @This();

allocator: Allocator,
tokens: ArrayList(Token),
reIdentifier: Regex,
reConstant: Regex,
reComment: Regex,

pub fn init(allocator: Allocator) !Lexer {
    return .{
        .allocator = allocator,
        .tokens = .empty,
        .reIdentifier = try .init("[a-zA-Z_]\\w*\\b"),
        .reConstant = try .init("[0-9]+\\b"),
        .reComment = try .init("//[^\n]*|/\\*([^*]|\\*+[^*/])*\\*+/"),
    };
}

pub fn deinit(self: *Lexer) void {
    defer self.reIdentifier.deinit();
    defer self.reConstant.deinit();
    defer self.reComment.deinit();
    defer self.tokens.deinit(self.allocator);
}

pub fn tokenize(self: *Lexer, text: [:0]const u8) ![]Token {
    var tokenStart: usize = 0;
    var lineNumber: usize = 1;
    while (tokenStart < text.len) {
        const nextToken = text[tokenStart..];
        const currentChar = nextToken[0];

        switch (currentChar) {
            'a'...'z', 'A'...'Z', '_' => {
                const token = self.reIdentifier.exec(nextToken) orelse badToken(nextToken, lineNumber);
                const tokenType = getIdentifierType(token);
                try self.tokens.append(self.allocator, .{ .type = tokenType, .value = token });
                tokenStart += token.len;
            },
            '0'...'9' => {
                const token = self.reConstant.exec(nextToken) orelse badToken(nextToken, lineNumber);
                try self.tokens.append(self.allocator, .{ .type = .Constant, .value = token });
                tokenStart += token.len;
            },
            '(', ')', '{', '}', ';' => {
                const token: Token = switch (currentChar) {
                    '(' => .{ .type = .OpenParenthesis, .value = "(" },
                    ')' => .{ .type = .CloseParenthesis, .value = ")" },
                    '{' => .{ .type = .OpenBrace, .value = "{" },
                    '}' => .{ .type = .CloseBrace, .value = "}" },
                    ';' => .{ .type = .Semicolon, .value = ";" },
                    else => unreachable,
                };
                try self.tokens.append(self.allocator, token);
                tokenStart += token.value.len;
            },
            ' ', '\t' => {
                tokenStart += 1;
            },
            '\n' => {
                lineNumber += 1;
                tokenStart += 1;
            },
            '/' => {
                const comment = self.reComment.exec(nextToken) orelse badToken(nextToken, lineNumber);
                tokenStart += comment.len;
            },
            else => {
                badToken(nextToken, lineNumber);
            },
        }
    }
    return self.tokens.items;
}

fn badToken(text: [:0]const u8, lineNumber: usize) noreturn {
    const reBadToken = Regex.init("\\S*") catch {
        std.process.fatal("Lexing error on line {d}", .{lineNumber});
    };

    const token = reBadToken.exec(text).?;
    std.process.fatal("Invalid symbol found '{s}' on line {d}", .{ token, lineNumber });
}
