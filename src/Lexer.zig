const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const Regex = @import("Lexer/Regex.zig");
pub const Token = @import("Lexer/Token.zig");
const TokenIterator = Token.Iterator;

const KeywordMap = std.StaticStringMap(Token.Type).initComptime(.{
    .{ "if", .If },
    .{ "int", .Int },
    .{ "else", .Else },
    .{ "return", .Return },
    .{ "void", .Void },
});

const Lexer = @This();

allocator: Allocator,
tokens: ArrayList(Token),
reIdentifier: Regex,
reConstant: Regex,
reComment: Regex,
reMacro: Regex,

pub fn init(allocator: Allocator) !Lexer {
    return .{
        .allocator = allocator,
        .tokens = .empty,
        .reIdentifier = try .init("[a-zA-Z_]\\w*\\b"),
        .reConstant = try .init("[0-9]+\\b"),
        .reComment = try .init("//[^\n]*|/\\*([^*]|\\*+[^*/])*\\*+/"),
        .reMacro = try .init("\\#[^\n]*"),
    };
}

pub fn deinit(self: *Lexer) void {
    defer self.reIdentifier.deinit();
    defer self.reConstant.deinit();
    defer self.reComment.deinit();
    defer self.reMacro.deinit();
    defer self.tokens.deinit(self.allocator);
}

pub fn tokenize(self: *Lexer, text: [:0]const u8) !TokenIterator {
    var tokenStart: usize = 0;
    var lineIndex: usize = 0;

    var prevToken: Token = undefined;
    while (tokenStart < text.len) {
        const remainingText = text[tokenStart..];
        const currentChar = remainingText[0];

        var token: Token = undefined;
        switch (currentChar) {
            'a'...'z', 'A'...'Z', '_' => { // identifiers and keywords
                const identifier = self.reIdentifier.exec(remainingText) orelse badToken(remainingText, lineIndex);
                const tokenType = KeywordMap.get(identifier) orelse .Identifier;
                token = .{ .type = tokenType, .symbol = identifier, .lineIndex = lineIndex };
            },
            '0'...'9' => { // constants
                const constant = self.reConstant.exec(remainingText) orelse badToken(remainingText, lineIndex);
                token = .{ .type = .Constant, .symbol = constant, .lineIndex = lineIndex };
            },
            '(', ')', '{', '}', ';' => { // brackets and semicolons
                token = switch (currentChar) {
                    '(' => .{ .type = .OpenParenthesis, .symbol = "(", .lineIndex = lineIndex },
                    ')' => .{ .type = .CloseParenthesis, .symbol = ")", .lineIndex = lineIndex },
                    '{' => .{ .type = .OpenBrace, .symbol = "{", .lineIndex = lineIndex },
                    '}' => .{ .type = .CloseBrace, .symbol = "}", .lineIndex = lineIndex },
                    ';' => .{ .type = .Semicolon, .symbol = ";", .lineIndex = lineIndex },
                    else => unreachable,
                };
            },
            '#' => { // ignore macros for now
                const macro = self.reMacro.exec(remainingText) orelse badToken(remainingText, lineIndex);
                tokenStart += macro.len;
                continue;
            },
            ' ', '\t' => { // ignore spaces and tabs
                tokenStart += 1;
                continue;
            },
            '\n' => { // ignore newlines, but increment lineIndex for debugging
                lineIndex += 1;
                tokenStart += 1;
                continue;
            },
            '/' => { // line and block comments; division operator
                switch (remainingText[1]) {
                    '/', '*' => { // comment
                        const comment = self.reComment.exec(remainingText) orelse badToken(remainingText, lineIndex);
                        tokenStart += comment.len;
                        continue;
                    },
                    '=' => { // division assignment operator
                        token = .{ .type = .BinaryOp, .symbol = "/=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex };
                    },
                    else => { // division binary operator
                        token = .{ .type = .BinaryOp, .symbol = "/", .precedence = 140, .associativity = .LeftToRight, .lineIndex = lineIndex };
                    },
                }
            },
            '~' => { // bitwise NOT operator (complement)
                token = .{ .type = .UnaryOp, .symbol = "~", .associativity = .RightToLeft, .lineIndex = lineIndex }; //
            },
            '!' => {
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "!=", .precedence = 100, .associativity = .LeftToRight, .lineIndex = lineIndex }, // not equal
                    else => .{ .type = .UnaryOp, .symbol = "!", .precedence = 150, .associativity = .RightToLeft, .lineIndex = lineIndex }, // logical NOT
                };
            },
            '-' => { // negation or subtraction
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "-=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // subtraction assignment
                    '-' => switch (prevToken.type) {
                        .Identifier, .CloseParenthesis => .{ .type = .UnaryOp, .symbol = "--", .precedence = 160, .associativity = .LeftToRight, .lineIndex = lineIndex },
                        else => .{ .type = .UnaryOp, .symbol = "--", .precedence = 150, .associativity = .RightToLeft, .lineIndex = lineIndex },
                    },
                    else => switch (prevToken.type) {
                        .Constant, .Identifier, .CloseParenthesis => .{ .type = .BinaryOp, .symbol = "-", .precedence = 130, .associativity = .LeftToRight, .lineIndex = lineIndex }, // subtract
                        else => .{ .type = .UnaryOp, .symbol = "-", .precedence = 150, .associativity = .LeftToRight, .lineIndex = lineIndex }, // unary negation
                    },
                };
            },
            '%' => { // modulo operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "%=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // modulo assignment
                    else => .{ .type = .BinaryOp, .symbol = "%", .precedence = 140, .associativity = .LeftToRight, .lineIndex = lineIndex }, // modulo
                };
            },
            '*' => { // multiplication operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "*=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // multiplication assignment
                    else => .{ .type = .BinaryOp, .symbol = "*", .precedence = 140, .associativity = .LeftToRight, .lineIndex = lineIndex }, // multiplication
                };
            },
            '+' => { // addition operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "+=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // addition assignment
                    '+' => switch (prevToken.type) {
                        .Identifier, .CloseParenthesis => .{ .type = .UnaryOp, .symbol = "++", .precedence = 160, .associativity = .LeftToRight, .lineIndex = lineIndex },
                        else => .{ .type = .UnaryOp, .symbol = "++", .precedence = 150, .associativity = .RightToLeft, .lineIndex = lineIndex },
                    },
                    else => .{ .type = .BinaryOp, .symbol = "+", .precedence = 130, .associativity = .LeftToRight, .lineIndex = lineIndex }, // addition
                };
            },
            '^' => { // XOR operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "^=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // bitwise XOR assignment
                    else => .{ .type = .BinaryOp, .symbol = "^", .precedence = 80, .associativity = .LeftToRight, .lineIndex = lineIndex }, // bitwise XOR
                };
            },
            '&' => {
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "&=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // bitwise AND assignment
                    '&' => .{ .type = .BinaryOp, .symbol = "&&", .precedence = 60, .associativity = .LeftToRight, .lineIndex = lineIndex }, // logical AND
                    else => .{ .type = .BinaryOp, .symbol = "&", .precedence = 90, .associativity = .LeftToRight, .lineIndex = lineIndex }, // bitwise AND
                };
            },
            '|' => {
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "|=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // bitwise OR assignment
                    '|' => .{ .type = .BinaryOp, .symbol = "||", .precedence = 50, .associativity = .LeftToRight, .lineIndex = lineIndex }, // logical OR
                    else => .{ .type = .BinaryOp, .symbol = "|", .precedence = 70, .associativity = .LeftToRight, .lineIndex = lineIndex }, // bitwise OR
                };
            },
            '=' => {
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "==", .precedence = 100, .associativity = .LeftToRight, .lineIndex = lineIndex },
                    else => .{ .type = .BinaryOp, .symbol = "=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex },
                };
            },
            '<' => { // shift left, less-than
                token = switch (remainingText[1]) {
                    '<' => switch (remainingText[2]) {
                        '=' => .{ .type = .BinaryOp, .symbol = "<<=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // bit-shift left assignment
                        else => .{ .type = .BinaryOp, .symbol = "<<", .precedence = 120, .associativity = .LeftToRight, .lineIndex = lineIndex }, // bit-shift left
                    },
                    '=' => .{ .type = .BinaryOp, .symbol = "<=", .precedence = 110, .associativity = .LeftToRight, .lineIndex = lineIndex }, // LTE
                    else => .{ .type = .BinaryOp, .symbol = "<", .precedence = 110, .associativity = .LeftToRight, .lineIndex = lineIndex }, // LT
                };
            },
            '>' => { // shift right, greater-than
                token = switch (remainingText[1]) {
                    //'>' => .{ .type = .BinaryOp, .symbol = ">>", .precedence = 120, .lineIndex = lineIndex }, // bit-shift right
                    '>' => switch (remainingText[2]) {
                        '=' => .{ .type = .BinaryOp, .symbol = ">>=", .precedence = 30, .associativity = .RightToLeft, .lineIndex = lineIndex }, // bit-shift right assignment
                        else => .{ .type = .BinaryOp, .symbol = ">>", .precedence = 120, .associativity = .LeftToRight, .lineIndex = lineIndex }, // bit-shift right
                    },
                    '=' => .{ .type = .BinaryOp, .symbol = ">=", .precedence = 110, .associativity = .LeftToRight, .lineIndex = lineIndex }, // GTE
                    else => .{ .type = .BinaryOp, .symbol = ">", .precedence = 110, .associativity = .LeftToRight, .lineIndex = lineIndex }, // GT
                };
            },
            '?' => token = .{ .type = .TernaryOp, .symbol = "?", .precedence = 40, .associativity = .RightToLeft, .lineIndex = lineIndex },
            ':' => token = .{ .type = .TernaryOp, .symbol = ":", .lineIndex = lineIndex },
            else => {
                badToken(remainingText, lineIndex);
            },
        }
        try self.tokens.append(self.allocator, token);
        prevToken = token;
        tokenStart += token.symbol.len;
    }
    return Token.iterate(self.tokens.items);
}

/// From the remaining text, find the first non-whitespace sequence to report as the invalid token
fn badToken(text: [:0]const u8, lineIndex: usize) noreturn {
    const lineNumber = lineIndex + 1;
    const reBadToken = Regex.init("\\S*") catch {
        std.process.fatal("Lexing error on line {d}", .{lineNumber});
    };

    const token = reBadToken.exec(text).?;
    std.process.fatal("Invalid symbol found '{s}' on line {d}", .{ token, lineNumber });
}
