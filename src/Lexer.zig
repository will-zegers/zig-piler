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

pub fn tokenize(self: *Lexer, text: [:0]const u8) ![]Token {
    var tokenStart: usize = 0;
    var lineNumber: usize = 1;

    var prevToken: Token = undefined;
    while (tokenStart < text.len) {
        const remainingText = text[tokenStart..];
        const currentChar = remainingText[0];

        var token: Token = undefined;
        switch (currentChar) {
            'a'...'z', 'A'...'Z', '_' => { // identifiers and keywords
                const identifier = self.reIdentifier.exec(remainingText) orelse badToken(remainingText, lineNumber);
                const tokenType = KeywordMap.get(identifier) orelse .Identifier;
                token = .{ .type = tokenType, .symbol = identifier };
            },
            '0'...'9' => { // constants
                const constant = self.reConstant.exec(remainingText) orelse badToken(remainingText, lineNumber);
                token = .{ .type = .Constant, .symbol = constant };
            },
            '(', ')', '{', '}', ';' => { // brackets and semicolons
                token = switch (currentChar) {
                    '(' => .{ .type = .OpenParenthesis, .symbol = "(" },
                    ')' => .{ .type = .CloseParenthesis, .symbol = ")" },
                    '{' => .{ .type = .OpenBrace, .symbol = "{" },
                    '}' => .{ .type = .CloseBrace, .symbol = "}" },
                    ';' => .{ .type = .Semicolon, .symbol = ";" },
                    else => unreachable,
                };
            },
            '#' => { // ignore macros for now
                const macro = self.reMacro.exec(remainingText) orelse badToken(remainingText, lineNumber);
                tokenStart += macro.len;
                continue;
            },
            ' ', '\t' => { // ignore spaces and tabs
                tokenStart += 1;
                continue;
            },
            '\n' => { // ignore newlines, but increment lineNumber for debugging
                lineNumber += 1;
                tokenStart += 1;
                continue;
            },
            '/' => { // line and block comments; division operator
                switch (remainingText[1]) {
                    '/', '*' => { // comment
                        const comment = self.reComment.exec(remainingText) orelse badToken(remainingText, lineNumber);
                        tokenStart += comment.len;
                        continue;
                    },
                    '=' => { // division assignment operator
                        token = .{ .type = .Assign, .symbol = "/=", .precedence = 30 };
                    },
                    else => { // division binary operator
                        token = .{ .type = .BinaryOp, .symbol = "/", .precedence = 140 };
                    },
                }
            },
            '~' => { // bitwise NOT operator (complement)
                token = .{ .type = .UnaryOp, .symbol = "~" }; //
            },
            '!' => {
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "!=", .precedence = 100 }, // not equal
                    else => .{ .type = .UnaryOp, .symbol = "!", .precedence = 150 }, // logical NOT
                };
            },
            '-' => { // negation or subtraction
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .Assign, .symbol = "-=", .precedence = 30 }, // subtraction assignment
                    else => switch (prevToken.type) {
                        .Constant, .Identifier, .CloseParenthesis => .{ .type = .BinaryOp, .symbol = "-", .precedence = 130 }, // subtract
                        else => .{ .type = .UnaryOp, .symbol = "-", .precedence = 150 }, // unary negation
                    },
                };
            },
            '%' => { // modulo operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .Assign, .symbol = "%=", .precedence = 30 }, // modulo assignment
                    else => .{ .type = .BinaryOp, .symbol = "%", .precedence = 140 }, // modulo
                };
            },
            '*' => { // multiplication operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .Assign, .symbol = "*=", .precedence = 30 }, // multiplication assignment
                    else => .{ .type = .BinaryOp, .symbol = "*", .precedence = 140 }, // multiplication
                };
            },
            '+' => { // addition operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .Assign, .symbol = "+=", .precedence = 30 }, // addition assignment
                    else => .{ .type = .BinaryOp, .symbol = "+", .precedence = 130 }, // addition
                };
            },
            '^' => { // XOR operator
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .Assign, .symbol = "^=", .precedence = 30 }, // bitwise XOR assignment
                    else => .{ .type = .BinaryOp, .symbol = "^", .precedence = 80 }, // bitwise XOR
                };
            },
            '&' => {
                token = switch (remainingText[1]) {
                    '&' => .{ .type = .BinaryOp, .symbol = "&&", .precedence = 60 }, // logical AND
                    '=' => .{ .type = .Assign, .symbol = "&=", .precedence = 30 }, // bitwise AND assignment
                    else => .{ .type = .BinaryOp, .symbol = "&", .precedence = 90 }, // bitwise AND
                };
            },
            '|' => {
                token = switch (remainingText[1]) {
                    '|' => .{ .type = .BinaryOp, .symbol = "||", .precedence = 50 }, // logical OR
                    '=' => .{ .type = .Assign, .symbol = "|=", .precedence = 30 },
                    else => .{ .type = .BinaryOp, .symbol = "|", .precedence = 70 }, // bitwise OR
                };
            },
            '=' => {
                token = switch (remainingText[1]) {
                    '=' => .{ .type = .BinaryOp, .symbol = "==", .precedence = 100 },
                    else => .{ .type = .Assign, .symbol = "=", .precedence = 30 },
                };
            },
            '<' => { // shift left, less-than
                token = switch (remainingText[1]) {
                    '<' => switch (remainingText[2]) {
                        '=' => .{ .type = .Assign, .symbol = "<<=", .precedence = 30 }, // bit-shift left assignment
                        else => .{ .type = .BinaryOp, .symbol = "<<", .precedence = 120 }, // bit-shift left
                    },
                    '=' => .{ .type = .BinaryOp, .symbol = "<=", .precedence = 110 }, // LTE
                    else => .{ .type = .BinaryOp, .symbol = "<", .precedence = 110 }, // LT
                };
            },
            '>' => { // shift right, greater-than
                token = switch (remainingText[1]) {
                    //'>' => .{ .type = .BinaryOp, .symbol = ">>", .precedence = 120 }, // bit-shift right
                    '>' => switch (remainingText[2]) {
                        '=' => .{ .type = .Assign, .symbol = ">>=", .precedence = 30 }, // bit-shift right assignment
                        else => .{ .type = .BinaryOp, .symbol = ">>", .precedence = 120 }, // bit-shift right
                    },
                    '=' => .{ .type = .BinaryOp, .symbol = ">=", .precedence = 110 }, // GTE
                    else => .{ .type = .BinaryOp, .symbol = ">", .precedence = 110 }, // GT
                };
            },
            else => {
                badToken(remainingText, lineNumber);
            },
        }
        try self.tokens.append(self.allocator, token);
        prevToken = token;
        tokenStart += token.symbol.len;
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
