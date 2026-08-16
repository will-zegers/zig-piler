const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const common = @import("Parser/common.zig");
const ParsingError = common.ParsingError;
const allocError = common.allocError;
const expect = common.expect;
const identifier = common.identifier;
const int = common.int;
const unexpectedEOF = common.unexpectedEOF;

const expression = @import("Parser/expression.zig");
pub const Expression = expression.Expression;
pub const Binary = expression.Binary;
pub const Unary = expression.Unary;
pub const Factor = expression.Factor;
pub const Constant = expression.Constant;
pub const Assignment = expression.Assignment;

const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const Parser = @This();

pub const AST = Program;

pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!AST {
    const ast = try Program.init(allocator, tokens);
    if (tokens.peek()) |token| {
        std.log.err("Unexpected token(s) at end of file: {s}", .{token.symbol});
        std.process.exit(1);
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
    body: Block,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Function {
        try expect(.Int, tokens.next());

        const token = tokens.next() orelse unexpectedEOF();
        try expect(.Identifier, token);

        try expect(.OpenParenthesis, tokens.next());
        try expect(.Void, tokens.next());
        try expect(.CloseParenthesis, tokens.next());

        return .{ .allocator = allocator, .name = token.symbol, .body = try .parse(allocator, tokens) };
    }

    pub fn deinit(self: *Function) void {
        self.body.deinit();
    }
};

pub const Block = struct {
    allocator: Allocator,
    items: []BlockItem,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Block {
        var blockList: ArrayList(BlockItem) = .empty;

        try expect(.OpenBrace, tokens.next());
        while (tokens.peek()) |nextToken| {
            if (.CloseBrace == nextToken.type) break;

            const blockItem = try BlockItem.parse(allocator, tokens);
            blockList.append(allocator, blockItem) catch allocError();
        }
        try expect(.CloseBrace, tokens.next());

        const items = blockList.toOwnedSlice(allocator) catch allocError();
        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(self: *Block) void {
        defer self.allocator.free(self.items);

        for (self.items) |*item| {
            item.deinit();
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
            .{ .Declaration = try .parse(allocator, tokens) }
        else
            .{ .Statement = try .parse(allocator, tokens) };
    }

    pub fn deinit(self: *BlockItem) void {
        switch (self.*) {
            .Statement => |*statement| Statement.deinit(statement),
            .Declaration => |*decl| decl.deinit(),
        }
    }
};

pub const Declaration = struct {
    name: identifier,
    init: ?Expression,
    lineIndex: usize,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Declaration {
        try expect(.Int, tokens.next());
        const token = tokens.peek() orelse unexpectedEOF();
        try expect(.Identifier, token);

        const init = try Assignment.parse(allocator, tokens);
        try expect(.Semicolon, tokens.next());

        return .{ .name = token.symbol, .init = init, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: *Declaration) void {
        if (self.*.init) |*init| Expression.deinit(init);
    }
};

pub const Break = struct {
    tag: identifier = undefined, // this will get set during semantic analysis
    lineIndex: usize,

    pub fn parse(tokens: *TokenIterator) ParsingError!Break {
        const token = tokens.next() orelse return unexpectedEOF();
        try expect(.Semicolon, tokens.next());
        return .{ .lineIndex = token.lineIndex };
    }
};

pub const Continue = struct {
    tag: identifier = undefined, // this will get set during semantic analysis
    lineIndex: usize,

    pub fn parse(tokens: *TokenIterator) ParsingError!Continue {
        const token = tokens.next() orelse return unexpectedEOF();
        try expect(.Semicolon, tokens.next());
        return .{ .lineIndex = token.lineIndex };
    }
};

pub const DoWhile = struct {
    allocator: Allocator,
    tag: identifier = undefined, // this will get set during semantic analysis
    body: *Statement,
    cond: Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!DoWhile {
        try expect(.Do, tokens.next());

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        try expect(.While, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());
        const cond = try Expression.parse(allocator, tokens, 0); // cond will be parsed in the '(' <expr> ')' form
        try expect(.Semicolon, tokens.peek());

        return .{ .allocator = allocator, .body = body, .cond = cond };
    }

    pub fn deinit(self: *DoWhile) void {
        Statement.deinit(self.body);
        self.allocator.destroy(self.body);

        Expression.deinit(&self.cond);
    }
};

const ForInitTag = enum { Declaration, Expression };
const ForInit = union(ForInitTag) {
    Declaration: Declaration,
    Expression: ?Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!ForInit {
        const nextToken = tokens.peek() orelse unexpectedEOF();
        return switch (nextToken.type) {
            .Int => .{ .Declaration = try .parse(allocator, tokens) },
            else => blk: {
                const expr: ?Expression = if (.Semicolon != nextToken.type)
                    try .parse(allocator, tokens, 0)
                else
                    null;
                try expect(.Semicolon, tokens.next());
                break :blk .{ .Expression = expr };
            },
        };
    }

    pub fn deinit(self: *ForInit) void {
        switch (self.*) {
            .Expression => if (self.*.Expression) |*expr| Expression.deinit(expr),
            .Declaration => self.*.Declaration.deinit(),
        }
    }
};

pub const For = struct {
    allocator: Allocator,
    tag: identifier = undefined, // this will get set during semantic analysis
    init: ForInit,
    cond: ?Expression,
    post: ?Expression,
    body: *Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!For {
        try expect(.For, tokens.next());
        try expect(.OpenParenthesis, tokens.next());

        const init: ForInit = try .parse(allocator, tokens);

        var nextToken = tokens.peek() orelse unexpectedEOF();
        const cond = if (.Semicolon != nextToken.type) try Expression.parse(allocator, tokens, 0) else null;
        try expect(.Semicolon, tokens.next());

        nextToken = tokens.peek() orelse unexpectedEOF();
        const post = if (.CloseParenthesis != nextToken.type) try Expression.parse(allocator, tokens, 0) else null;
        try expect(.CloseParenthesis, tokens.next());

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .allocator = allocator, .init = init, .cond = cond, .post = post, .body = body };
    }

    pub fn deinit(self: *For) void {
        self.init.deinit();
        if (self.cond) |*cond| Expression.deinit(cond);
        if (self.post) |*post| Expression.deinit(post);

        Statement.deinit(self.body);
        self.allocator.destroy(self.body);
    }
};

pub const While = struct {
    allocator: Allocator,
    tag: identifier = undefined, // this will get set during semantic analysis
    cond: Expression,
    body: *Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!While {
        try expect(.While, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());
        const cond = try Expression.parse(allocator, tokens, 0);

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .allocator = allocator, .cond = cond, .body = body };
    }

    pub fn deinit(self: *While) void {
        Expression.deinit(&self.cond);

        Statement.deinit(self.body);
        self.allocator.destroy(self.body);
    }
};

pub const Goto = struct {
    target: identifier,
    lineIndex: usize,

    pub fn parse(tokens: *TokenIterator) ParsingError!Goto {
        try expect(.Goto, tokens.next());

        const token = tokens.next() orelse unexpectedEOF();
        try expect(.Identifier, token);
        const self: Goto = .{ .target = token.symbol, .lineIndex = token.lineIndex };

        try expect(.Semicolon, tokens.next());

        return self;
    }
};

pub const If = struct {
    allocator: Allocator,
    condition: Expression,
    then: *Statement,
    else_: ?*Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!If {
        try expect(.If, tokens.next());
        try expect(.OpenParenthesis, tokens.peek()); // only peek, since parentheses will be handled while parsing the expr

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
        // no need to check for close parenthesis, since it's handled by the expression parser

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

pub const Switch = struct {
    allocator: Allocator,
    cond: Expression,
    body: *Statement,
    cases: ArrayList(Case) = .empty,
    tag: identifier = "",

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Switch {
        try expect(.Switch, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());

        const cond = try Expression.parse(allocator, tokens, 0);

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .allocator = allocator, .cond = cond, .body = body };
    }

    pub fn deinit(self: *Switch) void {
        for (self.cases.items) |*case| {
            case.deinit();
        }
        self.cases.deinit(self.allocator);

        Expression.deinit(&self.cond);

        Statement.deinit(self.body);
        self.allocator.destroy(self.body);
    }
};

pub const Case = struct {
    allocator: Allocator,
    cond: ?Expression,
    body: ArrayList(Statement),
    tag: identifier = "",
    lineIndex: usize,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Case {
        const nextToken = tokens.next() orelse unexpectedEOF();
        const cond: ?Expression = switch (nextToken.type) {
            .Case => try Expression.parse(allocator, tokens, 0),
            .Default => null,
            else => unreachable, // the statement parser already guards against other cases
        };
        if (cond != null and cond.? != .Constant) {
            std.log.err("Non-constant expression", .{});
            return ParsingError.NonConstExpr;
        }
        const lineIndex = nextToken.lineIndex;
        try expect(.Colon, tokens.next());

        var body: ArrayList(Statement) = .empty;
        while (tokens.peek()) |token| {
            switch (token.type) {
                .Case, .CloseBrace, .Default => break,
                else => {
                    const blockItem = try Statement.parse(allocator, tokens);
                    body.append(allocator, blockItem) catch allocError();
                },
            }
        }

        return .{ .allocator = allocator, .cond = cond, .body = body, .lineIndex = lineIndex };
    }

    pub fn deinit(self: *Case) void {
        if (self.cond) |*cond| {
            Expression.deinit(cond);
        }
        for (self.body.items) |*item| {
            item.deinit();
        }
        self.body.deinit(self.allocator);
    }
};

pub const Label = struct {
    allocator: Allocator,
    name: identifier,
    statement: *Statement,
    lineIndex: usize,

    pub fn parse(allocator: Allocator, name: Token, tokens: *TokenIterator) ParsingError!Label {
        try expect(.Identifier, name);
        try expect(.Colon, tokens.next());

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

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Return {
        try expect(.Return, tokens.next());
        const expr = try Expression.parse(allocator, tokens, 0);
        const self: Return = .{ .allocator = allocator, .expr = expr };
        try expect(.Semicolon, tokens.next());

        return self;
    }

    pub fn deinit(self: *Return) void {
        Expression.deinit(&self.expr);
    }
};

const StatementTag = enum { Break, Case, Compound, Continue, DoWhile, Expression, For, Goto, If, Label, Return, Switch, While, Null };
pub const Statement = union(StatementTag) {
    Break: Break,
    Case: Case,
    Compound: Block,
    Continue: Continue,
    DoWhile: DoWhile,
    Expression: Expression,
    For: For,
    Goto: Goto,
    If: If,
    Label: Label,
    Return: Return,
    Switch: Switch,
    While: While,
    Null: void, // needed to represent empty semicolon-delimited statements

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Statement {
        var nextToken = tokens.peek() orelse unexpectedEOF();
        return switch (nextToken.type) {
            .Break => .{ .Break = try .parse(tokens) },
            .Case, .Default => .{ .Case = try .parse(allocator, tokens) },
            .OpenBrace => .{ .Compound = try .parse(allocator, tokens) },
            .Continue => .{ .Continue = try .parse(tokens) },
            .Do => .{ .DoWhile = try .parse(allocator, tokens) },
            .Goto => .{ .Goto = try .parse(tokens) },
            .For => .{ .For = try .parse(allocator, tokens) },
            .If => .{ .If = try .parse(allocator, tokens) },
            .Return => .{ .Return = try .parse(allocator, tokens) },
            .While => .{ .While = try .parse(allocator, tokens) },
            .Semicolon => .{ .Null = tokens.skip() },
            .Switch => .{ .Switch = try .parse(allocator, tokens) },
            .Identifier => blk: { // <identifier> ':' <statement>
                const ident = tokens.next() orelse unexpectedEOF();
                nextToken = tokens.peek() orelse unexpectedEOF();
                if (nextToken.type == .Colon) { // labeled statement of the form <identifier> ':' <statement>
                    break :blk .{ .Label = try .parse(allocator, ident, tokens) };
                } else { // otherwise parse it as an expression of the form <expr> ';'
                    tokens.rewind();
                    const expr: Statement = .{ .Expression = try Expression.parse(allocator, tokens, 0) };
                    try expect(.Semicolon, tokens.next());
                    break :blk expr;
                }
            },
            else => blk: { // <expr> ';'
                const expr: Statement = .{ .Expression = try Expression.parse(allocator, tokens, 0) };
                try expect(.Semicolon, tokens.next());
                break :blk expr;
            },
        };
    }

    pub fn deinit(statement: *Statement) void {
        switch (statement.*) {
            .Compound => statement.*.Compound.deinit(),
            .DoWhile => statement.*.DoWhile.deinit(),
            .Expression => Expression.deinit(&statement.*.Expression),
            .For => statement.*.For.deinit(),
            .If => statement.*.If.deinit(),
            .Label => statement.*.Label.deinit(),
            .Null, .Goto => {},
            .Return => statement.*.Return.deinit(),
            .While => statement.*.While.deinit(),
            .Switch => statement.*.Switch.deinit(),
            .Case => statement.*.Case.deinit(),
            else => {},
        }
    }
};
