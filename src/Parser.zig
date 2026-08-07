const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fatal = std.process.fatal;
const ArrayList = std.ArrayList;

const expression = @import("Parser/expression.zig");
pub const expect = expression.expect;
pub const Expression = expression.Expression;
pub const Binary = expression.Binary;
pub const Unary = expression.Unary;
pub const Factor = expression.Factor;
pub const Constant = expression.Constant;
pub const Assignment = expression.Assignment;
pub const ParsingError = expression.ParsingError;

const Semantic = @import("Semantic.zig");
const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const Parser = @This();

pub const AST = Program;

const identifier = []const u8;
const int = []const u8;

pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!AST {
    const ast = try Program.init(allocator, tokens);
    if (tokens.peek()) |token| {
        fatal("Unexpected token(s) at end of file: {s}", .{token.symbol});
    }

    return ast;
}

pub const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Program {
        return .{ .allocator = allocator, .function = try .init(allocator, tokens) };
    }

    pub fn deinit(self: *Program) void {
        self.function.deinit();
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: identifier,
    body: std.ArrayList(BlockItem),

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Function {
        var body: ArrayList(BlockItem) = .empty;

        try expect(.Int, tokens.next());

        const token = tokens.next() orelse unexpectedEOF();
        try expect(.Identifier, token);

        try expect(.OpenParenthesis, tokens.next());
        try expect(.Void, tokens.next());
        try expect(.CloseParenthesis, tokens.next());

        try expect(.OpenBrace, tokens.next());
        while (tokens.peek()) |nextToken| {
            if (.CloseBrace == nextToken.type) break;

            const blockItem = try BlockItem.parse(allocator, tokens);
            body.append(allocator, blockItem) catch allocError();
        }
        try expect(.CloseBrace, tokens.next());

        return .{ .allocator = allocator, .name = token.symbol, .body = body };
    }

    pub fn deinit(self: *Function) void {
        defer self.body.deinit(self.allocator);

        for (self.body.items) |*blockItem| {
            switch (blockItem.*) {
                .Statement => |*statement| Statement.deinit(statement),
                .Declaration => |*decl| {
                    if (decl.initialize) |*initExpr| {
                        Expression.deinit(initExpr);
                    }
                },
            }
        }
    }
};

pub const BlockItemTag = enum { Declaration, Statement };
pub const BlockItem = union(BlockItemTag) {
    Declaration: Declaration,
    Statement: Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!BlockItem {
        const nextToken = tokens.peek() orelse unexpectedEOF();
        return if (.Int == nextToken.type)
            .{ .Declaration = try .init(allocator, tokens) }
        else
            .{ .Statement = try .parse(allocator, tokens) };
    }
};

const StatementTag = enum { Expression, Goto, If, Label, Return, Null };
pub const Statement = union(StatementTag) {
    Expression: Expression,
    Goto: Goto,
    If: If,
    Label: Label,
    Return: Return,
    Null: void, // needed to represent empty semicolon statements (for later?)

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Statement {
        var nextToken = tokens.peek() orelse unexpectedEOF();
        return switch (nextToken.type) {
            .Goto => blk: { // goto <identifier> ';'
                try expect(.Goto, tokens.next());
                const stmt: Statement = .{ .Goto = try .init(tokens) };
                try expect(.Semicolon, tokens.next());
                break :blk stmt;
            },
            .If => blk: { // if '(' <expr> ')' <statement> [else <statement>]
                try expect(.If, tokens.next());
                try expect(.OpenParenthesis, tokens.peek());
                break :blk .{ .If = try .init(allocator, tokens) };
            },
            .Identifier => blk: { // <identifier> ':' <statement>
                const ident = tokens.next() orelse unexpectedEOF();
                nextToken = tokens.peek() orelse unexpectedEOF();
                if (nextToken.type == .Colon) { // labeled statement of the form <identifier> ':' <statement>
                    try expect(.Identifier, ident);
                    try expect(.Colon, tokens.next());
                    break :blk .{ .Label = try .init(allocator, ident, tokens) };
                } else { // otherwise parse it as an expression of the form <expr> ';'
                    tokens.rewind();
                    const expr: Statement = .{ .Expression = try Expression.parse(allocator, tokens, 0) };
                    try expect(.Semicolon, tokens.next());
                    break :blk expr;
                }
            },
            .Return => blk: { // return <expr> ';'
                try expect(.Return, tokens.next());
                const stmt: Statement = .{ .Return = try .init(allocator, tokens) };
                try expect(.Semicolon, tokens.next());
                break :blk stmt;
            },
            .Semicolon => .{ .Null = tokens.skip() },
            else => blk: { // <expr> ';'
                const expr: Statement = .{ .Expression = try Expression.parse(allocator, tokens, 0) };
                try expect(.Semicolon, tokens.next());
                break :blk expr;
            },
        };
    }

    pub fn deinit(statement: *Statement) void {
        switch (statement.*) {
            .Return => statement.*.Return.deinit(),
            .Expression => Expression.deinit(&statement.*.Expression),
            .Null, .Goto => {},
            .If => statement.*.If.deinit(),
            .Label => statement.*.Label.deinit(),
        }
    }
};

pub const If = struct {
    allocator: Allocator,
    condition: Expression,
    then: *Statement,
    else_: ?*Statement,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!If {
        const condition = try Expression.parse(allocator, tokens, 0);

        const then = allocator.create(Statement) catch allocError();
        then.* = try .parse(allocator, tokens);

        var else_: ?*Statement = null;
        const nextToken = tokens.peek() orelse unexpectedEOF();
        if (.Else == nextToken.type) { // if-else...
            tokens.skip(); // discard the 'else' token

            else_ = allocator.create(Statement) catch allocError();
            else_.?.* = try .parse(allocator, tokens);
        }

        return .{ .allocator = allocator, .condition = condition, .then = then, .else_ = else_ };
    }

    pub fn deinit(self: *If) void {
        defer {
            self.allocator.destroy(self.then);
        }

        Expression.deinit(&self.condition);
        Statement.deinit(self.then);
        if (self.else_) |*else_| {
            defer self.allocator.destroy(else_.*);
            Statement.deinit(else_.*);
        }
    }
};

pub const Goto = struct {
    label: identifier,
    lineIndex: usize,

    pub fn init(tokens: *TokenIterator) ParsingError!Goto {
        const label = tokens.next() orelse unexpectedEOF();
        try expect(.Identifier, label);

        return .{ .label = label.symbol, .lineIndex = label.lineIndex };
    }
};

pub const Label = struct {
    allocator: Allocator,
    name: identifier,
    statement: *Statement,
    lineIndex: usize,

    pub fn init(allocator: Allocator, name: Token, tokens: *TokenIterator) ParsingError!Label {
        const statement = allocator.create(Statement) catch allocError();
        statement.* = try Statement.parse(allocator, tokens);

        return .{ .allocator = allocator, .name = name.symbol, .statement = statement, .lineIndex = name.lineIndex };
    }

    pub fn deinit(self: *Label) void {
        defer self.allocator.destroy(self.statement);
        Statement.deinit(self.statement);
    }
};

pub const Return = struct {
    allocator: Allocator,
    expr: Expression,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Return {
        const expr = try Expression.parse(allocator, tokens, 0);
        return .{ .allocator = allocator, .expr = expr };
    }

    pub fn deinit(self: *Return) void {
        Expression.deinit(&self.expr);
    }
};

pub const Declaration = struct {
    name: identifier,
    initialize: ?Expression,
    lineIndex: usize,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Declaration {
        try expect(.Int, tokens.next());
        const token = tokens.peek() orelse unexpectedEOF();
        try expect(.Identifier, token);

        const initialize = try Assignment.parse(allocator, tokens);
        try expect(.Semicolon, tokens.next());

        return .{ .name = token.symbol, .initialize = initialize, .lineIndex = token.lineIndex };
    }
};

fn unexpectedEOF() noreturn {
    std.log.err("Unexpected end of file", .{});
    std.process.exit(1);
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
