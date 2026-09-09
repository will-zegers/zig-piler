const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const Token = @import("../Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const common = @import("common.zig");
const ParsingError = common.ParsingError;
const allocError = common.allocError;
const expect = common.expect;
const identifier = common.identifier;
const int = common.int;

pub const ExpressionTag = enum {
    Constant,
    Var,
    Unary,
    Binary,
    Assignment,
    Ternary,
    FunctionCall,
};

pub const Expression = union(ExpressionTag) {
    Constant: Constant,
    Var: Var,
    Unary: Unary,
    Binary: Binary,
    Assignment: Assignment,
    Ternary: Ternary,
    FunctionCall: FunctionCall,

    /// Evaluates expression from left-to-right for arithmetic, or right-to-left for assignment, operators.
    /// This is a recursive descent parser that uses the precedence climbing algorithm.
    pub fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) ParsingError!Expression {
        var left = try parseFactor(allocator, tokens);

        var nextToken = tokens.peek();
        while (nextToken.associativity != .None and nextToken.precedence >= minPrecedence) {
            nextToken = tokens.next();
            if (nextToken.associativity == .RightToLeft) {
                left = blk: switch (nextToken.type) {
                    .TernaryOp => { // <expr> '?' <expr> ':' <expr>
                        const ternaryPrecedence = nextToken.precedence;

                        try expect(.TernaryOp, nextToken);
                        const middle = try parse(allocator, tokens, 0);

                        nextToken = tokens.next();
                        try expect(.Colon, nextToken);
                        const right = try parse(allocator, tokens, ternaryPrecedence); // use the same precedence for the right side of the ternary operator

                        const temp = try Ternary.init(allocator, left, middle, right);
                        break :blk .{ .Ternary = temp };
                    },
                    .BinaryOp => { // <expr> '='|'+='|'-='|'*='|'/='|'%='|'&='|'|=' <expr>
                        const right = try parse(allocator, tokens, nextToken.precedence);
                        const temp = try Assignment.init(allocator, nextToken, left, right);
                        break :blk .{ .Assignment = temp };
                    },
                    else => return unexpectedToken(nextToken),
                };
            } else {
                left = switch (nextToken.type) {
                    .UnaryOp => blk: { // <factor> '++'|'--'
                        const temp = try Unary.initPost(allocator, nextToken, left);
                        break :blk .{ .Unary = temp };
                    },
                    .BinaryOp => blk: { // <expr> '+'|'-'|'*'|'/'|'%'|'&'|'|' <expr>
                        const right = try parse(allocator, tokens, nextToken.precedence + 1);
                        const temp = try Binary.init(allocator, nextToken, left, right);
                        break :blk .{ .Binary = temp };
                    },
                    else => return unexpectedToken(nextToken),
                };
            }
            nextToken = tokens.peek();
        }

        return left;
    }

    pub fn deinit(expr: *Expression, allocator: Allocator) void {
        switch (expr.*) {
            .Constant, .Var => {},
            .Unary => expr.Unary.deinit(allocator),
            .Binary => expr.Binary.deinit(allocator),
            .Assignment => expr.Assignment.deinit(allocator),
            .Ternary => expr.Ternary.deinit(allocator),
            .FunctionCall => expr.FunctionCall.deinit(allocator),
        }
    }
};

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) ParsingError!Expression {
    const token = tokens.next();
    const expr: Expression = switch (token.type) {
        .Constant => .{ .Constant = token.symbol },
        .UnaryOp => blk: { // '~'|'!'|'-'|'++'|'--' <factor>
            const right = try parseFactor(allocator, tokens);
            break :blk .{ .Unary = try Unary.initPre(allocator, token, right) };
        },
        .Identifier => blk: {
            const nextToken = tokens.peek();
            if (nextToken.type == .OpenParenthesis) { // check if this a function call
                tokens.rewind(); // back up to process all parts of the function call
                break :blk .{ .FunctionCall = try .parse(allocator, tokens) };
            } else { // otherwise it's just a plain variable
                break :blk .{ .Var = .{ .name = token.symbol, .lineIndex = token.lineIndex } };
            }
        },
        .OpenParenthesis => blk: { // '(' <expr> ')'
            const expr = try Expression.parse(allocator, tokens, 0);
            const next = tokens.next();
            if (next.type != .CloseParenthesis) return unexpectedToken(token);
            break :blk expr;
        },
        else => return unexpectedToken(token),
    };

    const nextToken = tokens.peek();
    if (nextToken.type == .UnaryOp) { // '~'|'!'|'-'|'++'|'--' <factor> '++'|'--'
        return .{ .Unary = try .initPost(allocator, tokens.next(), expr) };
    }

    return expr;
}

pub const Constant = int;

pub const Var = struct {
    name: identifier,
    lineIndex: usize,
};

pub const Unary = struct {
    pub const Operator = enum {
        Complement,
        Negate,
        Not,
        Inc,
        Dec,
    };

    const OperatorMap = std.StaticStringMap(Operator).initComptime(.{
        .{ "~", .Complement },
        .{ "-", .Negate },
        .{ "!", .Not },
        .{ "++", .Inc },
        .{ "--", .Dec },
    });

    operator: Operator,
    operand: *Expression,
    type: enum { Pre, Post },
    lineIndex: usize,

    pub fn initPost(allocator: Allocator, token: Token, right: Expression) ParsingError!Unary {
        if (!mem.eql(u8, "++", token.symbol) and !mem.eql(u8, "--", token.symbol)) return unexpectedToken(token);

        const operand = allocator.create(Expression) catch allocError();
        operand.* = right;

        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);
        return .{ .operator = operator, .operand = operand, .type = .Post, .lineIndex = token.lineIndex };
    }

    pub fn initPre(allocator: Allocator, token: Token, left: Expression) ParsingError!Unary {
        const operand = allocator.create(Expression) catch allocError();
        operand.* = left;

        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);
        return .{ .operator = operator, .operand = operand, .type = .Pre, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: *Unary, allocator: Allocator) void {
        defer allocator.destroy(self.operand);

        Expression.deinit(self.operand, allocator);
    }
};

pub const Binary = struct {
    pub const Operator = enum {
        Add,
        AndB,
        AndL,
        Div,
        Eq,
        Gt,
        Gte,
        Lt,
        Lte,
        Mod,
        Mul,
        Neq,
        OrB,
        OrL,
        SAL,
        SAR,
        Sub,
        Xor,
    };

    const OperatorMap = std.StaticStringMap(Operator).initComptime(.{
        .{ "+", .Add },
        .{ "&", .AndB },
        .{ "&&", .AndL },
        .{ "/", .Div },
        .{ "==", .Eq },
        .{ ">", .Gt },
        .{ ">=", .Gte },
        .{ "<", .Lt },
        .{ "<=", .Lte },
        .{ "%", .Mod },
        .{ "*", .Mul },
        .{ "!=", .Neq },
        .{ "|", .OrB },
        .{ "||", .OrL },
        .{ "<<", .SAL },
        .{ ">>", .SAR },
        .{ "-", .Sub },
        .{ "^", .Xor },
    });

    operator: Operator,
    left: *Expression,
    right: *Expression,

    pub fn init(allocator: Allocator, token: Token, left: Expression, right: Expression) ParsingError!Binary {
        const operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);

        const leftPtr = allocator.create(Expression) catch allocError();
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocError();
        rightPtr.* = right;

        return .{ .operator = operator, .left = leftPtr, .right = rightPtr };
    }

    pub fn deinit(self: Binary, allocator: Allocator) void {
        defer allocator.destroy(self.left);
        defer allocator.destroy(self.right);

        Expression.deinit(self.left, allocator);
        Expression.deinit(self.right, allocator);
    }
};

pub const Assignment = struct {
    const OperatorMap = std.StaticStringMap(Binary.Operator).initComptime(.{
        .{ "+=", Binary.Operator.Add },
        .{ "&=", Binary.Operator.AndB },
        .{ "/=", Binary.Operator.Div },
        .{ "%=", Binary.Operator.Mod },
        .{ "*=", Binary.Operator.Mul },
        .{ "|=", Binary.Operator.OrB },
        .{ "<<=", Binary.Operator.SAL },
        .{ ">>=", Binary.Operator.SAR },
        .{ "-=", Binary.Operator.Sub },
        .{ "^=", Binary.Operator.Xor },
    });

    operator: ?Binary.Operator,
    lhs: *Expression,
    rhs: *Expression,
    lineIndex: usize,

    pub fn init(allocator: Allocator, token: Token, lhs: Expression, rhs: Expression) ParsingError!Assignment {
        const operator = if (mem.eql(u8, "=", token.symbol))
            null
        else
            OperatorMap.get(token.symbol);

        const lhsPtr = allocator.create(Expression) catch allocError();
        lhsPtr.* = lhs;

        const rhsPtr = allocator.create(Expression) catch allocError();
        rhsPtr.* = rhs;

        return .{ .operator = operator, .lhs = lhsPtr, .rhs = rhsPtr, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: Assignment, allocator: Allocator) void {
        defer allocator.destroy(self.lhs);
        defer allocator.destroy(self.rhs);

        Expression.deinit(self.lhs, allocator);
        Expression.deinit(self.rhs, allocator);
    }

    pub fn fromDecl(allocator: Allocator, tokens: *TokenIterator) ParsingError!?Expression {
        const lhs = try parseFactor(allocator, tokens);
        if (lhs != .Var) {
            std.log.err("Expression type {any} is not an assignable lvalue", .{lhs});
            return ParsingError.Lvalue;
        }
        const nextToken = tokens.peek();
        return if (mem.eql(u8, "=", nextToken.symbol)) blk: {
            const operator = tokens.next();
            const rhs = try Expression.parse(allocator, tokens, 0);
            break :blk .{ .Assignment = try .init(allocator, operator, lhs, rhs) };
        } else null;
    }
};

pub const Ternary = struct {
    condition: *Expression,
    thenStmt: *Expression,
    elseStmt: *Expression,

    pub fn init(allocator: Allocator, left: Expression, middle: Expression, right: Expression) ParsingError!Ternary {
        const condition = allocator.create(Expression) catch allocError();
        condition.* = left;

        const thenStmt = allocator.create(Expression) catch allocError();
        thenStmt.* = middle;

        const elseStmt = allocator.create(Expression) catch allocError();
        elseStmt.* = right;

        return .{ .condition = condition, .thenStmt = thenStmt, .elseStmt = elseStmt };
    }

    pub fn deinit(self: *Ternary, allocator: Allocator) void {
        defer allocator.destroy(self.condition);
        defer allocator.destroy(self.thenStmt);
        defer allocator.destroy(self.elseStmt);

        Expression.deinit(self.condition, allocator);
        Expression.deinit(self.thenStmt, allocator);
        Expression.deinit(self.elseStmt, allocator);
    }
};

pub const FunctionCall = struct {
    lineIndex: usize,
    name: identifier,
    args: []Expression,

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!FunctionCall {
        const name = tokens.next();
        try expect(.Identifier, name);
        try expect(.OpenParenthesis, tokens.next());
        const args = try parseArgumentList(allocator, tokens);
        try expect(.CloseParenthesis, tokens.next());

        return .{ .lineIndex = name.lineIndex, .name = name.symbol, .args = args };
    }

    pub fn deinit(self: *FunctionCall, allocator: Allocator) void {
        for (self.args) |*arg| {
            Expression.deinit(arg, allocator);
        }
        allocator.free(self.args);
    }

    fn parseArgumentList(allocator: Allocator, tokens: *TokenIterator) ParsingError![]Expression {
        var args: std.ArrayList(Expression) = .empty;

        var nextToken = tokens.peek();
        if (nextToken.type != .CloseParenthesis) {
            while (true) {
                args.append(allocator, try .parse(allocator, tokens, 0)) catch allocError();

                nextToken = tokens.peek();
                if (nextToken.type == .CloseParenthesis) break;
                try expect(.Comma, tokens.next());
            }
        }

        return args.toOwnedSlice(allocator) catch allocError();
    }
};

fn unexpectedToken(token: Token) ParsingError {
    std.log.err("Got unexpected {any} token '{s}'", .{ token.type, token.symbol });
    return ParsingError.Token;
}
