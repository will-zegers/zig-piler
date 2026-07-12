const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const Regex = @import("Lexer/Regex.zig");
const tok = @import("token.zig");
const Token = tok.Token;
const TokenType = tok.TokenType;
const KeywordMap = tok.KeywordMap;

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
                const identifier = self.reIdentifier.exec(nextToken) orelse badToken(nextToken, lineNumber);
                const tokenType = KeywordMap.get(identifier) orelse .Identifier;
                try self.tokens.append(self.allocator, .{ .type = tokenType, .value = identifier });
                tokenStart += identifier.len;
            },
            '0'...'9' => {
                const constant = self.reConstant.exec(nextToken) orelse badToken(nextToken, lineNumber);
                try self.tokens.append(self.allocator, .{ .type = .Constant, .value = constant });
                tokenStart += constant.len;
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
            '-' => {
                const token: Token = if (nextToken[1] == '-')
                    .{ .type = .Decrement, .value = "--" }
                else
                    .{ .type = .Negate, .value = "-" };

                try self.tokens.append(self.allocator, token);
                tokenStart += 1;
            },
            '~' => {
                try self.tokens.append(self.allocator, .{ .type = .Negate, .value = "~" });
                tokenStart += 1;
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
