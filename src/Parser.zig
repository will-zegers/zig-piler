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

pub const AST = struct {
    allocator: Allocator,
    tree: Program,

    pub fn deinit(self: *AST, allocator: Allocator) void {
        self.tree.deinit(allocator);
    }
};

pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!AST {
    const program = try Program.init(allocator, tokens);
    if (!tokens.eofReached()) {
        const token = tokens.next();
        std.log.err("Unexpected token(s) at end of file: {s}", .{token.symbol});
        std.process.exit(1);
    }

    return .{ .allocator = allocator, .tree = program };
}

pub const Program = struct {
    functions: []FunDecl,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) ParsingError!Program {
        var functions: std.ArrayList(FunDecl) = .empty;
        while (!tokens.eofReached()) {
            functions.append(allocator, try .parse(allocator, tokens)) catch allocError();
        }
        return .{ .functions = functions.toOwnedSlice(allocator) catch allocError() };
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.functions) |*function| {
            function.deinit(allocator);
        }
        allocator.free(self.functions);
    }
};

pub const DeclarationTag = enum { FunDecl, VarDecl };
pub const Declaration = union(DeclarationTag) {
    FunDecl: FunDecl,
    VarDecl: VarDecl,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Declaration {
        // We need to look a couple tokens ahead to determine if this is a function declaration,
        // which be of the form "int" <identifier> "(" (i.e., the 'marker' be an open paranthesis).
        // If not, assume it a variable declaration of the form "int" <identifier> (";" | "=") and
        // try to parse it as such;
        const markerToken = tokens.lookAhead(2);
        return switch (markerToken.type) {
            .OpenParenthesis => .{ .FunDecl = try .parse(allocator, tokens) },
            else => .{ .VarDecl = try .parse(allocator, tokens) },
        };
    }

    pub fn deinit(self: *Declaration, allocator: Allocator) void {
        switch (self.*) {
            .FunDecl => self.*.FunDecl.deinit(allocator),
            .VarDecl => self.*.VarDecl.deinit(allocator),
        }
    }
};

pub const FunDecl = struct {
    lineIndex: usize,
    name: identifier,
    params: []VarDecl,
    body: ?Block,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!FunDecl {
        try expect(.Int, tokens.next());

        const name = tokens.next();
        try expect(.Identifier, name);

        try expect(.OpenParenthesis, tokens.next());
        const params = try parseParamsList(allocator, tokens);
        try expect(.CloseParenthesis, tokens.next());

        const token = tokens.peek();
        const body: ?Block = if (token.type == .OpenBrace)
            try Block.parse(allocator, tokens)
        else blk: {
            try expect(.Semicolon, tokens.next());
            break :blk null;
        };

        return .{ .name = name.symbol, .params = params, .body = body, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: *FunDecl, allocator: Allocator) void {
        if (self.body) |*body| {
            body.deinit(allocator);
        }

        for (self.params) |*param| {
            param.deinit(allocator);
        }
        allocator.free(self.params);
    }

    fn parseParamsList(allocator: Allocator, tokens: *TokenIterator) ParsingError![]VarDecl {
        var params: std.ArrayList(VarDecl) = .empty;

        var nextToken = tokens.peek();
        if (nextToken.type != .Void) {
            while (true) {
                params.append(allocator, try .asParam(allocator, tokens)) catch allocError();

                nextToken = tokens.peek();

                if (nextToken.type == .CloseParenthesis) break;
                try expect(.Comma, tokens.next());
            }
        } else {
            tokens.skip(); // No params, skip the void token
        }

        return params.toOwnedSlice(allocator) catch allocError();
    }
};

pub const VarDecl = struct {
    lineIndex: usize,
    name: identifier,
    init: ?Expression = null,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!VarDecl {
        try expect(.Int, tokens.next());

        const token = tokens.peek();
        try expect(.Identifier, token);

        const init = try Assignment.fromDecl(allocator, tokens);
        try expect(.Semicolon, tokens.next());

        return .{ .lineIndex = token.lineIndex, .name = token.symbol, .init = init };
    }

    pub fn asParam(allocator: Allocator, tokens: *TokenIterator) ParsingError!VarDecl {
        try expect(.Int, tokens.next());

        const token = tokens.next();
        try expect(.Identifier, token);

        const name = allocator.dupe(u8, token.symbol) catch allocError();

        return .{ .lineIndex = token.lineIndex, .name = name };
    }

    pub fn deinit(self: *VarDecl, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.*.init) |*init| Expression.deinit(init, allocator);
    }
};

pub const BlockItemTag = enum { Declaration, Statement };
pub const BlockItem = union(BlockItemTag) {
    Declaration: Declaration,
    Statement: Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!BlockItem {
        const nextToken = tokens.peek();
        return if (.Int == nextToken.type)
            .{ .Declaration = try .parse(allocator, tokens) }
        else
            .{ .Statement = try .parse(allocator, tokens) };
    }

    pub fn deinit(self: *BlockItem, allocator: Allocator) void {
        switch (self.*) {
            .Statement => |*statement| Statement.deinit(statement, allocator),
            .Declaration => |*decl| Declaration.deinit(decl, allocator),
        }
    }
};

pub const Block = struct {
    tag: ?[]const u8 = null,
    items: []BlockItem,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Block {
        var blockList: ArrayList(BlockItem) = .empty;

        try expect(.OpenBrace, tokens.next());
        while (tokens.peek().type != .CloseBrace) {
            const blockItem = try BlockItem.parse(allocator, tokens);
            blockList.append(allocator, blockItem) catch allocError();
        }
        try expect(.CloseBrace, tokens.next());

        const items = blockList.toOwnedSlice(allocator) catch allocError();
        return .{ .items = items };
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
    }
};

pub const Break = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null, // this will get set during semantic analysis

    pub fn parse(tokens: *TokenIterator) ParsingError!Break {
        const token = tokens.next();
        try expect(.Semicolon, tokens.next());
        return .{ .lineIndex = token.lineIndex };
    }

    // no deinit needed since the tag is owned by the enclosing loop/switch
};

pub const Continue = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null, // this will get set during semantic analysis

    pub fn parse(tokens: *TokenIterator) ParsingError!Continue {
        const token = tokens.next();
        try expect(.Semicolon, tokens.next());
        return .{ .lineIndex = token.lineIndex };
    }

    // no deinit needed since the tag is owned by the enclosing loop
};

pub const DoWhile = struct {
    tag: ?[]const u8 = null, // this will get set during semantic analysis
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

        return .{ .body = body, .cond = cond };
    }

    pub fn deinit(self: *DoWhile, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        Statement.deinit(self.body, allocator);
        allocator.destroy(self.body);

        Expression.deinit(&self.cond, allocator);
    }
};

const ForInitTag = enum { Declaration, Expression };
const ForInit = union(ForInitTag) {
    Declaration: Declaration,
    Expression: ?Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!ForInit {
        const nextToken = tokens.peek();
        return switch (nextToken.type) {
            .Int => .{ .Declaration = .{ .VarDecl = try .parse(allocator, tokens) } },
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

    pub fn deinit(self: *ForInit, allocator: Allocator) void {
        switch (self.*) {
            // TODO:
            .Expression => if (self.*.Expression) |*expr| Expression.deinit(expr, allocator),
            .Declaration => |*decl| Declaration.deinit(decl, allocator),
        }
    }
};

pub const For = struct {
    tag: ?[]const u8 = null, // this will get set during semantic analysis
    init: ForInit,
    cond: ?Expression,
    post: ?Expression,
    body: *Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!For {
        try expect(.For, tokens.next());
        try expect(.OpenParenthesis, tokens.next());

        const init: ForInit = try .parse(allocator, tokens);

        var nextToken = tokens.peek();
        const cond = if (.Semicolon != nextToken.type) try Expression.parse(allocator, tokens, 0) else null;
        try expect(.Semicolon, tokens.next());

        nextToken = tokens.peek();
        const post = if (.CloseParenthesis != nextToken.type) try Expression.parse(allocator, tokens, 0) else null;
        try expect(.CloseParenthesis, tokens.next());

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .init = init, .cond = cond, .post = post, .body = body };
    }

    pub fn deinit(self: *For, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        self.init.deinit(allocator);
        if (self.cond) |*cond| Expression.deinit(cond, allocator);
        if (self.post) |*post| Expression.deinit(post, allocator);

        Statement.deinit(self.body, allocator);
        allocator.destroy(self.body);
    }
};

pub const While = struct {
    tag: ?[]const u8 = null, // this will get set during semantic analysis
    cond: Expression,
    body: *Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!While {
        try expect(.While, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());
        const cond = try Expression.parse(allocator, tokens, 0);

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .cond = cond, .body = body };
    }

    pub fn deinit(self: *While, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        Expression.deinit(&self.cond, allocator);

        Statement.deinit(self.body, allocator);
        allocator.destroy(self.body);
    }
};

pub const Goto = struct {
    lineIndex: usize,
    target: identifier,

    pub fn parse(tokens: *TokenIterator) ParsingError!Goto {
        try expect(.Goto, tokens.next());

        const token = tokens.next();
        try expect(.Identifier, token);
        const self: Goto = .{ .target = token.symbol, .lineIndex = token.lineIndex };

        try expect(.Semicolon, tokens.next());

        return self;
    }
};

pub const If = struct {
    condition: Expression,
    thenStmt: *Statement,
    elseStmt: ?*Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!If {
        try expect(.If, tokens.next());
        try expect(.OpenParenthesis, tokens.peek()); // only peek, since parentheses will be handled while parsing the expr

        const condition = try Expression.parse(allocator, tokens, 0);

        const thenStmt = allocator.create(Statement) catch allocError();
        thenStmt.* = try .parse(allocator, tokens);

        var elseStmt: ?*Statement = null;
        const nextToken = tokens.peek();
        if (.Else == nextToken.type) { // if-else...
            tokens.skip(); // discard the 'else' token

            elseStmt = allocator.create(Statement) catch allocError();
            elseStmt.?.* = try .parse(allocator, tokens);
        }
        // no need to check for close parenthesis, since it's handled by the expression parser

        return .{ .condition = condition, .thenStmt = thenStmt, .elseStmt = elseStmt };
    }

    pub fn deinit(self: *If, allocator: Allocator) void {
        defer allocator.destroy(self.thenStmt);

        Expression.deinit(&self.condition, allocator);
        Statement.deinit(self.thenStmt, allocator);
        if (self.elseStmt) |*elseStmt| {
            defer allocator.destroy(elseStmt.*);
            Statement.deinit(elseStmt.*, allocator);
        }
    }
};

pub const Switch = struct {
    tag: ?[]const u8 = null,
    cond: Expression,
    body: *Statement,
    cases: ArrayList(*Case) = .empty,
    defaultTag: ?[]const u8 = null,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Switch {
        try expect(.Switch, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());

        const cond = try Expression.parse(allocator, tokens, 0);

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .cond = cond, .body = body };
    }

    pub fn addCase(self: *Switch, allocator: Allocator, case: *Case) ParsingError!void {
        for (self.cases.items) |child| { // ensure this is not a duplicate case
            if (std.mem.eql(u8, child.tag.?, case.*.tag.?)) return ParsingError.DuplicateCase;
        }

        // a case with no conditional signifies a default statement
        if (case.cond == null) self.defaultTag = case.tag;

        self.cases.append(allocator, case) catch allocError();
    }

    pub fn deinit(self: *Switch, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        Expression.deinit(&self.cond, allocator);

        Statement.deinit(self.body, allocator);
        allocator.destroy(self.body);

        // Case statement entries in '.cases' already delloc'd in the body dealloc
        self.cases.deinit(allocator);
    }
};

pub const Case = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null,
    cond: ?Expression,
    body: ?*Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Case {
        var nextToken = tokens.next();
        const cond: ?Expression = switch (nextToken.type) {
            .Case => try Expression.parse(allocator, tokens, 0),
            .Default => null, // 'default' is just treated as special "case" with no cond expr
            else => unreachable, // the statement parser already guards against other cases
        };

        // No current support for chars or the 'const' keyword, so only expect null or literal constants
        if (cond != null and cond.? != .Constant) {
            std.log.err("Non-constant expression", .{});
            return ParsingError.NonConstExpr;
        }
        const lineIndex = nextToken.lineIndex;
        try expect(.Colon, tokens.next());

        var body: ?*Statement = null;
        nextToken = tokens.peek();
        if (nextToken.type != .Case and nextToken.type != .Default) {
            body = allocator.create(Statement) catch allocError();
            body.?.* = try Statement.parse(allocator, tokens);
        }

        return .{ .lineIndex = lineIndex, .cond = cond, .body = body };
    }

    pub fn deinit(self: *Case, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        if (self.cond) |*cond| {
            Expression.deinit(cond, allocator);
        }

        if (self.body) |body| {
            Statement.deinit(body, allocator);
            allocator.destroy(body);
        }
    }
};

pub const Label = struct {
    lineIndex: usize,
    name: []const u8,
    tag: ?[]const u8 = null,
    body: *Statement,

    pub fn parse(allocator: Allocator, name: Token, tokens: *TokenIterator) ParsingError!Label {
        try expect(.Identifier, name);
        try expect(.Colon, tokens.next());

        const body = allocator.create(Statement) catch allocError();
        body.* = try Statement.parse(allocator, tokens);

        return .{ .name = name.symbol, .body = body, .lineIndex = name.lineIndex };
    }

    pub fn deinit(self: *Label, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        defer allocator.destroy(self.body);
        Statement.deinit(self.body, allocator);
    }
};

pub const Return = struct {
    expr: Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!Return {
        try expect(.Return, tokens.next());
        const expr = try Expression.parse(allocator, tokens, 0);
        const self: Return = .{ .expr = expr };
        try expect(.Semicolon, tokens.next());

        return self;
    }

    pub fn deinit(self: *Return, allocator: Allocator) void {
        Expression.deinit(&self.expr, allocator);
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
        const nextToken = tokens.peek();
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
                // We need to check if the token after the the identifier is a ':', in which case process the
                // the token stream as a label; otherwise, parse it as an expression
                const markerToken = tokens.lookAhead(1);
                if (markerToken.type == .Colon) {
                    const ident = tokens.next();
                    break :blk .{ .Label = try .parse(allocator, ident, tokens) };
                } else {
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

    // TODO:
    pub fn deinit(statement: *Statement, allocator: Allocator) void {
        switch (statement.*) {
            .Compound => statement.*.Compound.deinit(allocator),
            .DoWhile => statement.*.DoWhile.deinit(allocator),
            .Expression => Expression.deinit(&statement.*.Expression, allocator),
            .For => statement.*.For.deinit(allocator),
            .If => statement.*.If.deinit(allocator),
            .Label => statement.*.Label.deinit(allocator),
            .Null, .Goto => {},
            .Return => statement.*.Return.deinit(allocator),
            .While => statement.*.While.deinit(allocator),
            .Switch => statement.*.Switch.deinit(allocator),
            .Case => statement.*.Case.deinit(allocator),
            .Break, .Continue => {},
        }
    }
};
