const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Regex = @import("Lexer/Regex.zig");

const Self = @This();

allocator: Allocator,
tokens: ArrayList([]const u8),
reIdentifier: Regex,
reConstant: Regex,
reComment: Regex,

pub fn init(allocator: Allocator) !Self {
    return .{
        .allocator = allocator,
        .tokens = .empty,
        .reIdentifier = try .init("[a-zA-Z_]\\w*\\b"),
        .reConstant = try .init("[0-9]+\\b"),
        .reComment = try .init("//[^\n]*|/\\*([^*]|\\*+[^*/])*\\*+/"),
    };
}

pub fn deinit(self: *Self) void {
    defer self.reIdentifier.deinit();
    defer self.reConstant.deinit();
    defer self.reComment.deinit();
    defer self.tokens.deinit(self.allocator);
}

pub fn tokenize(self: *Self, text: [:0]const u8) ![][]const u8 {
    var tokenStart: usize = 0;
    var lineNumber: usize = 1;
    while (tokenStart < text.len) {
        const nextToken = text[tokenStart..];
        const currentChar = nextToken[0];

        switch (currentChar) {
            'a'...'z', 'A'...'Z', '_' => {
                const token = self.reIdentifier.exec(nextToken) orelse badToken(nextToken, lineNumber);
                try self.tokens.append(self.allocator, token);
                tokenStart += token.len;
            },
            '0'...'9' => {
                const token = self.reConstant.exec(nextToken) orelse badToken(nextToken, lineNumber);
                try self.tokens.append(self.allocator, token);
                tokenStart += token.len;
            },
            '(', ')', '{', '}', ';' => {
                const token = switch (currentChar) {
                    '(' => "(",
                    ')' => ")",
                    '{' => "{",
                    '}' => "}",
                    ';' => ";",
                    else => unreachable,
                };
                try self.tokens.append(self.allocator, token);
                tokenStart += token.len;
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
