const std = @import("std");
const ArrayList = std.ArrayList;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const common = @import("Parser/common.zig");
const Error = common.ParserError;
const ExpectedErrors = common.ExpectedErrors;
const Specifiers = common.Specifiers;
const StorageClass = common.StorageClass;
const expect = common.expect;
const identifier = common.identifier;

const Declarator = @import("Parser/declarator.zig").Declarator;

const expression = @import("Parser/expression.zig");
pub const Assignment = expression.Assignment;
pub const Binary = expression.Binary;
pub const Cast = expression.Cast;
pub const Constant = expression.Constant;
pub const Expression = expression.Expression;
pub const Factor = expression.Factor;
pub const FunctionCall = expression.FunctionCall;
pub const Ternary = expression.Ternary;
pub const Unary = expression.Unary;

pub const Type = @import("Parser/type.zig").Type;

const Parser = @This();

pub const AST = Program;

pub fn parse(allocator: Allocator, tokens: *TokenIterator, textLines: [][]const u8) ExpectedErrors!AST {
    const program = Program.parse(allocator, tokens) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                // TODO: can only catch and log one error at a time. Maybe try to
                // make this more granular at the function/declaration level to
                // catch more errors at once
                const index = tokens.lineIndex;
                log.err(" {d} | {s}\n", .{ index + 1, textLines[index] });
                process.exit(1);
            },
        }
    };
    if (!tokens.eofReached()) {
        const token = tokens.next();
        std.log.err("Unexpected token(s) at end of file: {s}", .{token.symbol});
        std.process.exit(1);
    }

    return program;
}

pub const Program = struct {
    allocator: Allocator,
    declarations: []Declaration,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Program {
        var declarations: ArrayList(Declaration) = .empty;
        while (!tokens.eofReached()) {
            try declarations.append(allocator, try .parse(allocator, tokens));
        }
        return .{ .allocator = allocator, .declarations = try declarations.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Program, allocator: Allocator) void {
        for (self.declarations) |*declaration| {
            declaration.deinit(allocator);
        }
        allocator.free(self.declarations);
    }
};

pub const Declaration = union(enum) {
    FunDecl: FunDecl,
    VarDecl: VarDecl,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Declaration {
        const lineIndex = tokens.peek().lineIndex;

        const specifiers = try Specifiers.parse(tokens);

        const declarator = try Declarator.parse(allocator, tokens);
        defer declarator.deinit(allocator);

        const name, const t, const params = try processDeclarator(allocator, declarator, specifiers.type.?);

        if (t == .FunType) {
            return .{ .FunDecl = try .parse(allocator, specifiers.storageClass, t, name, params, lineIndex, tokens) };
        } else {
            return .{ .VarDecl = try .parse(allocator, specifiers.storageClass, t, name, lineIndex, tokens) };
        }
    }

    fn processDeclarator(allocator: Allocator, declarator: Declarator, baseType: Type) ExpectedErrors!struct { []const u8, Type, [][]const u8 } {
        var paramNames: ArrayList([]const u8) = .empty;
        switch (declarator) {
            .Identifier => |i| return .{ i.name, baseType, try paramNames.toOwnedSlice(allocator) },
            .Pointer => |d| {
                const ref = try allocator.create(Type);
                ref.* = baseType;
                const derivedType: Type = .{ .Pointer = .{ .referenced = ref } };

                return processDeclarator(allocator, d.decl.*, derivedType);
            },
            .Function => |f| {
                if (f.decl.* != .Identifier) {
                    log.err("Can't apply additional type derivations to a function type", .{});
                    return Parser.Error.AdditionalFunctionDerivation;
                }

                var paramTypes: ArrayList(*Type) = .empty;
                for (f.paramInfo) |param| {
                    const name, const ty, _ = try processDeclarator(allocator, param.decl, param.type);
                    if (ty == .FunType) {
                        log.err("Function pointers in params are not supported", .{});
                        return Parser.Error.FunctionPointerInParams;
                    }
                    try paramNames.append(allocator, name);

                    const t = try allocator.create(Type);
                    t.* = ty;
                    try paramTypes.append(allocator, t);
                }
                const ret = try allocator.create(Type);
                ret.* = baseType;

                const derivedType: Type = .{ .FunType = .{ .params = try paramTypes.toOwnedSlice(allocator), .ret = ret } };
                return .{ f.decl.Identifier.name, derivedType, try paramNames.toOwnedSlice(allocator) };
            },
        }
    }

    pub fn deinit(self: *Declaration, allocator: Allocator) void {
        switch (self.*) {
            .FunDecl => self.FunDecl.deinit(allocator),
            .VarDecl => self.VarDecl.deinit(allocator),
        }
    }
};

pub const FunDecl = struct {
    lineIndex: usize,
    storageClass: ?StorageClass,
    type: Type,
    name: identifier,
    params: [][]const u8,
    body: ?Block,
    resolved: bool = false, // Semantic analysis will allocate unique names for parameters that need deinit

    pub fn parse(
        allocator: Allocator,
        storageClass: ?StorageClass,
        t: Type,
        name: []const u8,
        params: [][]const u8,
        lineIndex: usize,
        tokens: *TokenIterator,
    ) ExpectedErrors!FunDecl {
        var body: ?Block = null;
        if (tokens.peek().type == .OpenBrace) {
            body = try Block.parse(allocator, tokens);
        } else {
            try expect(.Semicolon, tokens.next());
        }

        return .{
            .lineIndex = lineIndex,
            .storageClass = storageClass,
            .type = t,
            .name = name,
            .params = params,
            .body = body,
        };
    }

    pub fn deinit(self: *FunDecl, allocator: Allocator) void {
        if (self.body) |*body| {
            body.deinit(allocator);
        }

        if (self.resolved) {
            for (self.params) |param| {
                allocator.free(param);
            }
        }
        allocator.free(self.params);
        self.type.deinit(allocator);
    }
};

pub const VarDecl = struct {
    lineIndex: usize,
    storageClass: ?StorageClass = null,
    type: Type,
    name: []const u8,
    unique: ?[]const u8 = null,
    init: ?Expression = null,

    pub fn parse(
        allocator: Allocator,
        storageClass: ?StorageClass,
        t: Type,
        name: []const u8,
        lineIndex: usize,
        tokens: *TokenIterator,
    ) ExpectedErrors!VarDecl {
        var init: ?Expression = null;
        if (mem.eql(u8, "=", tokens.peek().symbol)) {
            const lhs: Expression = .{ .Var = .{ .type = t, .name = name, .lineIndex = lineIndex } };
            const token = tokens.next();
            const rhs: Expression = try .parse(allocator, tokens, 0);
            init = .{ .Assignment = try Assignment.parse(allocator, token, lhs, rhs) };
        }
        try expect(.Semicolon, tokens.next());

        return .{
            .lineIndex = lineIndex,
            .storageClass = storageClass,
            .type = t,
            .name = name,
            .init = init,
        };
    }

    pub fn deinit(self: *VarDecl, allocator: Allocator) void {
        if (self.unique) |unique| allocator.free(unique);
        if (self.init) |*init| init.deinit(allocator);
        self.type.deinit(allocator);
    }
};

pub const BlockItem = union(enum) {
    Declaration: Declaration,
    Statement: Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!BlockItem {
        const nextToken = tokens.peek();
        return switch (nextToken.type) {
            .Double, .Extern, .Int, .Long, .Signed, .Static, .Unsigned => .{ .Declaration = try .parse(allocator, tokens) },
            else => .{ .Statement = try .parse(allocator, tokens) },
        };
    }

    pub fn deinit(self: *BlockItem, allocator: Allocator) void {
        switch (self.*) {
            .Statement => |*statement| statement.deinit(allocator),
            .Declaration => |*decl| decl.deinit(allocator),
        }
    }
};

pub const Block = struct {
    tag: ?[]const u8 = null,
    items: []BlockItem,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Block {
        var blockList: ArrayList(BlockItem) = .empty;

        try expect(.OpenBrace, tokens.next());
        while (tokens.peek().type != .CloseBrace) {
            const blockItem = try BlockItem.parse(allocator, tokens);
            try blockList.append(allocator, blockItem);
        }
        try expect(.CloseBrace, tokens.next());

        const items = try blockList.toOwnedSlice(allocator);
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

pub const Statement = union(enum) {
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

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Statement {
        const nextToken = tokens.peek();
        return switch (nextToken.type) {
            .Break => .{ .Break = try .parse(tokens) },
            .Case, .Default => .{ .Case = try .parse(allocator, tokens) },
            .Continue => .{ .Continue = try .parse(tokens) },
            .Do => .{ .DoWhile = try .parse(allocator, tokens) },
            .For => .{ .For = try .parse(allocator, tokens) },
            .Goto => .{ .Goto = try .parse(tokens) },
            .Identifier => blk: { // <identifier> ':' <statement>
                // We need to check if the token after the the identifier is a ':', in which case process the
                // the token stream as a label; otherwise, parse it as an expression
                const markerToken = tokens.lookAhead(1);
                if (markerToken.type == .Colon) {
                    const ident = tokens.next();
                    break :blk .{ .Label = try .parse(allocator, ident, tokens) };
                } else {
                    const expr: Statement = .{ .Expression = try .parse(allocator, tokens, 0) };
                    try expect(.Semicolon, tokens.next());
                    break :blk expr;
                }
            },
            .If => .{ .If = try .parse(allocator, tokens) },
            .OpenBrace => .{ .Compound = try .parse(allocator, tokens) },
            .Return => .{ .Return = try .parse(allocator, tokens) },
            .Semicolon => .{ .Null = tokens.skip() },
            .Switch => .{ .Switch = try .parse(allocator, tokens) },
            .While => .{ .While = try .parse(allocator, tokens) },
            else => blk: { // <expr> ';'
                const expr: Statement = .{ .Expression = try .parse(allocator, tokens, 0) };
                try expect(.Semicolon, tokens.next());
                break :blk expr;
            },
        };
    }

    pub fn deinit(statement: *Statement, allocator: Allocator) void {
        switch (statement.*) {
            .Break, .Continue => {},
            .Case => statement.Case.deinit(allocator),
            .Compound => statement.Compound.deinit(allocator),
            .DoWhile => statement.DoWhile.deinit(allocator),
            .Expression => Expression.deinit(&statement.Expression, allocator),
            .For => statement.For.deinit(allocator),
            .If => statement.If.deinit(allocator),
            .Label => statement.Label.deinit(allocator),
            .Null, .Goto => {},
            .Return => statement.Return.deinit(allocator),
            .Switch => statement.Switch.deinit(allocator),
            .While => statement.While.deinit(allocator),
        }
    }
};

pub const Break = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null, // this will get set during semantic analysis

    pub fn parse(tokens: *TokenIterator) Parser.Error!Break {
        const token = tokens.next();
        try expect(.Semicolon, tokens.next());
        return .{ .lineIndex = token.lineIndex };
    }

    // no deinit needed since the tag is owned by the enclosing loop/switch
};

pub const Case = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null,
    cond: ?Expression,
    body: ?*Statement,
    parent: ?*Switch = null,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Case {
        var nextToken = tokens.next();
        const cond: ?Expression = switch (nextToken.type) {
            .Case => try .parse(allocator, tokens, 0),
            .Default => null, // 'default' is just treated as special "case" with no cond expr
            else => unreachable, // the statement parser already guards against other cases
        };

        const lineIndex = nextToken.lineIndex;
        try expect(.Colon, tokens.next());

        var body: ?*Statement = null;
        nextToken = tokens.peek();
        if (nextToken.type != .Case and nextToken.type != .Default) {
            body = try allocator.create(Statement);
            body.?.* = try .parse(allocator, tokens);
        }

        return .{ .lineIndex = lineIndex, .cond = cond, .body = body };
    }

    pub fn registerToParentSwitch(self: *Case, allocator: Allocator) ExpectedErrors!void {
        self.tag = try self.generateTag(allocator);
        return self.parent.?.addCase(allocator, self);
    }

    // Generate a tag with parent tag and condition constant
    // In addition, assure we're comparing like-types between case condition
    // and switch cond types, truncating case conditions if need be
    pub fn generateTag(self: *Case, allocator: Allocator) Allocator.Error![]const u8 {
        std.debug.assert(self.parent != null); // This shouldn't occur, since we catch orphan case before tagging

        const parentType = self.parent.?.cond.getType();
        if (self.cond) |cond| {
            switch (cond) {
                .Constant => switch (parentType) {
                    .Int, .UInt => {
                        const value = cond.Constant.as(.UInt);
                        return allocator.print("{s}.{d}", .{ self.parent.?.tag.?, value.uint });
                    },
                    .Long, .ULong => {
                        const value = cond.Constant.as(.ULong);
                        return allocator.print("{s}.{d}", .{ self.parent.?.tag.?, value.ulong });
                    },
                    .Double, .FunType, .Pointer => unreachable,
                },
                .Cast => switch (parentType) {
                    .Int, .UInt => {
                        const value = cond.Cast.exp.Constant.as(.UInt);
                        return allocator.print("{s}.{d}", .{ self.parent.?.tag.?, value.uint });
                    },
                    .Long, .ULong => {
                        const value = cond.Cast.exp.Constant.as(.ULong);
                        return allocator.print("{s}.{d}", .{ self.parent.?.tag.?, value.ulong });
                    },
                    .Double, .FunType, .Pointer => unreachable,
                },
                else => unreachable,
            }
        } else {
            return allocator.print("{s}.default", .{self.parent.?.tag.?}) catch unreachable;
        }
    }

    pub fn deinit(self: *Case, allocator: Allocator) void {
        if (self.tag) |tag| {
            allocator.free(tag);
        }

        if (self.cond) |*cond| {
            cond.deinit(allocator);
        }

        if (self.body) |body| {
            body.deinit(allocator);
            allocator.destroy(body);
        }
    }
};

pub const Continue = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null, // this will get set during semantic analysis

    pub fn parse(tokens: *TokenIterator) Parser.Error!Continue {
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

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!DoWhile {
        try expect(.Do, tokens.next());

        const body = try allocator.create(Statement);
        body.* = try .parse(allocator, tokens);

        try expect(.While, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());
        const cond: Expression = try .parse(allocator, tokens, 0); // cond will be parsed in the '(' <expr> ')' form
        try expect(.Semicolon, tokens.peek());

        return .{ .body = body, .cond = cond };
    }

    pub fn deinit(self: *DoWhile, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        self.body.deinit(allocator);
        allocator.destroy(self.body);

        self.cond.deinit(allocator);
    }
};

const ForInit = union(enum) {
    Declaration: Declaration,
    Expression: ?Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!ForInit {
        const nextToken = tokens.peek();
        switch (nextToken.type) {
            .Double, .Int, .Long, .Extern, .Signed, .Static, .Unsigned => {
                const decl: Declaration = try .parse(allocator, tokens);
                if (decl == .FunDecl) {
                    log.err("Expected variable declarator or expression", .{});
                    return Parser.Error.ForLoopFunDecl;
                }

                return .{ .Declaration = decl };
            },
            else => {
                const expr: ?Expression = if (.Semicolon != nextToken.type)
                    try .parse(allocator, tokens, 0)
                else
                    null;

                try expect(.Semicolon, tokens.next());
                return .{ .Expression = expr };
            },
        }
    }

    pub fn deinit(self: *ForInit, allocator: Allocator) void {
        switch (self.*) {
            .Expression => if (self.Expression) |*expr| expr.deinit(allocator),
            .Declaration => |*decl| decl.deinit(allocator),
        }
    }
};

pub const For = struct {
    tag: ?[]const u8 = null, // this will get set during semantic analysis
    init: ForInit,
    cond: ?Expression,
    post: ?Expression,
    body: *Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!For {
        try expect(.For, tokens.next());
        try expect(.OpenParenthesis, tokens.next());

        const init: ForInit = try .parse(allocator, tokens);

        var nextToken = tokens.peek();
        const cond: ?Expression = if (.Semicolon != nextToken.type) try .parse(allocator, tokens, 0) else null;
        try expect(.Semicolon, tokens.next());

        nextToken = tokens.peek();
        const post: ?Expression = if (.CloseParenthesis != nextToken.type) try .parse(allocator, tokens, 0) else null;
        try expect(.CloseParenthesis, tokens.next());

        const body = try allocator.create(Statement);
        body.* = try .parse(allocator, tokens);

        return .{ .init = init, .cond = cond, .post = post, .body = body };
    }

    pub fn deinit(self: *For, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        self.init.deinit(allocator);
        if (self.cond) |*cond| cond.deinit(allocator);
        if (self.post) |*post| post.deinit(allocator);

        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};

pub const Goto = struct {
    lineIndex: usize,
    target: identifier,

    pub fn parse(tokens: *TokenIterator) Parser.Error!Goto {
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

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!If {
        try expect(.If, tokens.next());
        try expect(.OpenParenthesis, tokens.peek()); // only peek, since parentheses will be handled while parsing the expr

        const condition: Expression = try .parse(allocator, tokens, 0);

        const thenStmt = try allocator.create(Statement);
        thenStmt.* = try .parse(allocator, tokens);

        var elseStmt: ?*Statement = null;
        const nextToken = tokens.peek();
        if (.Else == nextToken.type) { // if-else...
            tokens.skip(); // discard the 'else' token

            elseStmt = try allocator.create(Statement);
            elseStmt.?.* = try .parse(allocator, tokens);
        }
        // no need to check for close parenthesis, since it's handled by the expression parser

        return .{ .condition = condition, .thenStmt = thenStmt, .elseStmt = elseStmt };
    }

    pub fn deinit(self: *If, allocator: Allocator) void {
        defer allocator.destroy(self.thenStmt);

        self.condition.deinit(allocator);
        self.thenStmt.deinit(allocator);
        if (self.elseStmt) |*elseStmt| {
            defer allocator.destroy(elseStmt.*);
            elseStmt.*.deinit(allocator);
        }
    }
};

pub const Label = struct {
    lineIndex: usize,
    name: []const u8,
    tag: ?[]const u8 = null,
    body: *Statement,

    pub fn parse(allocator: Allocator, name: Token, tokens: *TokenIterator) ExpectedErrors!Label {
        try expect(.Identifier, name);
        try expect(.Colon, tokens.next());

        const body = try allocator.create(Statement);
        body.* = try .parse(allocator, tokens);

        return .{ .name = name.symbol, .body = body, .lineIndex = name.lineIndex };
    }

    pub fn deinit(self: *Label, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        defer allocator.destroy(self.body);
        self.body.deinit(allocator);
    }
};

pub const Return = struct {
    expr: Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Return {
        try expect(.Return, tokens.next());
        const expr: Expression = try .parse(allocator, tokens, 0);
        const self: Return = .{ .expr = expr };
        try expect(.Semicolon, tokens.next());

        return self;
    }

    pub fn deinit(self: *Return, allocator: Allocator) void {
        self.expr.deinit(allocator);
    }
};

pub const Switch = struct {
    lineIndex: usize,
    tag: ?[]const u8 = null,
    cond: Expression,
    body: *Statement,
    cases: ArrayList(*Case),
    defaultTag: ?[]const u8 = null,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!Switch {
        const token = tokens.next();
        try expect(.Switch, token);
        try expect(.OpenParenthesis, tokens.peek());

        const cond: Expression = try .parse(allocator, tokens, 0);

        const body = try allocator.create(Statement);
        body.* = try .parse(allocator, tokens);

        return .{ .lineIndex = token.lineIndex, .cond = cond, .body = body, .cases = .empty };
    }

    pub fn addCase(self: *Switch, allocator: Allocator, case: *Case) ExpectedErrors!void {
        for (self.cases.items) |child| { // ensure this is not a duplicate case
            if (mem.eql(u8, child.tag.?, case.tag.?)) return Parser.Error.DuplicateCase;
        }

        // a case with no conditional signifies a default statement
        if (case.cond == null) self.defaultTag = case.tag.?;

        try self.cases.append(allocator, case);
    }

    pub fn deinit(self: *Switch, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        self.cond.deinit(allocator);

        self.body.deinit(allocator);
        allocator.destroy(self.body);

        // Case statement entries in '.cases' already delloc'd in the body dealloc
        self.cases.deinit(allocator);
    }
};

pub const While = struct {
    tag: ?[]const u8 = null, // this will get set during semantic analysis
    cond: Expression,
    body: *Statement,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ExpectedErrors!While {
        try expect(.While, tokens.next());
        try expect(.OpenParenthesis, tokens.peek());
        const cond: Expression = try .parse(allocator, tokens, 0);

        const body = try allocator.create(Statement);
        body.* = try .parse(allocator, tokens);

        return .{ .cond = cond, .body = body };
    }

    pub fn deinit(self: *While, allocator: Allocator) void {
        if (self.tag) |tag| allocator.free(tag);

        self.cond.deinit(allocator);
        self.body.deinit(allocator);
        allocator.destroy(self.body);
    }
};
