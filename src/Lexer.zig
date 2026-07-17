const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const Regex = @import("Lexer/Regex.zig");
pub const Token = @import("Lexer/Token.zig");

const KeywordMap = std.StaticStringMap(Token.Type).initComptime(.{
    .{ "int", .Int },
    .{ "return", .Return },
    .{ "void", .Void },
});

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
            'a'...'z', 'A'...'Z', '_' => { // identifiers and keywords
                const identifier = self.reIdentifier.exec(nextToken) orelse badToken(nextToken, lineNumber);
                const tokenType = KeywordMap.get(identifier) orelse .Identifier;
                try self.tokens.append(self.allocator, .{ .type = tokenType, .symbol = identifier });
                tokenStart += identifier.len;
            },
            '0'...'9' => { // constants
                const constant = self.reConstant.exec(nextToken) orelse badToken(nextToken, lineNumber);
                try self.tokens.append(self.allocator, .{ .type = .Constant, .symbol = constant });
                tokenStart += constant.len;
            },
            '(', ')', '{', '}', ';' => { // brackets and semicolons
                const token: Token = switch (currentChar) {
                    '(' => .{ .type = .OpenParenthesis, .symbol = "(" },
                    ')' => .{ .type = .CloseParenthesis, .symbol = ")" },
                    '{' => .{ .type = .OpenBrace, .symbol = "{" },
                    '}' => .{ .type = .CloseBrace, .symbol = "}" },
                    ';' => .{ .type = .Semicolon, .symbol = ";" },
                    else => unreachable,
                };
                try self.tokens.append(self.allocator, token);
                tokenStart += token.symbol.len;
            },
            ' ', '\t' => { // ignore tabs
                tokenStart += 1;
            },
            '\n' => { // ignore newlines, but increment lineNumber for debugging
                lineNumber += 1;
                tokenStart += 1;
            },
            '/' => {
                switch (nextToken[1]) {
                    '/', '*' => { // comment
                        const comment = self.reComment.exec(nextToken) orelse badToken(nextToken, lineNumber);
                        tokenStart += comment.len;
                    },
                    else => { // division binary operator
                        const token: Token = .{ .type = .BinaryOp, .symbol = "/", .precedence = 64 };
                        try self.tokens.append(self.allocator, token);
                        tokenStart += token.symbol.len;
                    },
                }
            },
            '-', '~' => { // unary operators
                const token: Token = switch (currentChar) {
                    '-' => switch (nextToken[1]) {
                        ' ', '\t', '\n' => .{ .type = .BinaryOp, .symbol = "-", .precedence = 32 }, // subtract
                        else => .{ .type = .UnaryOp, .symbol = "-" }, // binary
                    },
                    '~' => .{ .type = .UnaryOp, .symbol = "~" },
                    else => unreachable,
                };
                try self.tokens.append(self.allocator, token);
                tokenStart += token.symbol.len;
            },
            '%', '*', '+' => { // binary operators (apart from division, handled above)
                const token: Token = switch (currentChar) {
                    '%' => .{ .type = .BinaryOp, .symbol = "%", .precedence = 64 },
                    '*' => .{ .type = .BinaryOp, .symbol = "*", .precedence = 64 },
                    '+' => .{ .type = .BinaryOp, .symbol = "+", .precedence = 32 },
                    else => unreachable,
                };
                try self.tokens.append(self.allocator, token);
                tokenStart += token.symbol.len;
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
