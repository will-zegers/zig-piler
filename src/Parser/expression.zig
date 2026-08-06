const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const Token = @import("../Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const identifier = []const u8;
const int = []const u8;

pub const ParsingError = error{
    EOF,
    Lvalue,
    Syntax,
    Token,
};

pub const ExpressionTag = enum {
    Constant,
    Var,
    Unary,
    Binary,
    Assignment,
    Ternary,
};

pub const Expression = union(ExpressionTag) {
    Constant: Constant,
    Var: Var,
    Unary: Unary,
    Binary: Binary,
    Assignment: Assignment,
    Ternary: Ternary,

    /// Evaluates expression from left-to-right for arithmetic, or right-to-left for assignment, operators.
    /// This is a recursive descent parser that uses the precedence climbing algorithm.
    pub fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) ParsingError!Expression {
        var left = try parseFactor(allocator, tokens);

        var nextToken = tokens.peek() orelse return unexpectedEOF();
        while (nextToken.associativity != .None and nextToken.precedence >= minPrecedence) {
            nextToken = tokens.next() orelse return unexpectedEOF();
            if (nextToken.associativity == .RightToLeft) {
                left = blk: switch (nextToken.type) {
                    .TernaryOp => { // <expr> '?' <expr> ':' <expr>
                        if (!mem.eql(u8, "?", nextToken.symbol)) return unexpectedToken(nextToken); // discard the '?'
                        const middle = try parse(allocator, tokens, 0);

                        nextToken = tokens.next() orelse return unexpectedEOF();
                        if (!mem.eql(u8, ":", nextToken.symbol)) return unexpectedToken(nextToken); // discard the '?'
                        const right = try parse(allocator, tokens, nextToken.precedence);

                        const temp = try Ternary.init(allocator, left, middle, right);
                        break :blk .{ .Ternary = temp };
                    },
                    .BinaryOp => { // <expr> '='|'+='|'-='|'*='|'/='|'%='|'&='|'|=' <expr>
                        const right = try parse(allocator, tokens, nextToken.precedence);
                        const temp = try Assignment.init(allocator, nextToken, left, right);
                        break :blk .{ .Assignment = temp };
                    },
                    else => unreachable,
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
                    else => unreachable,
                };
            }
            nextToken = tokens.peek() orelse return unexpectedEOF();
        }

        return left;
    }

    pub fn deinit(expr: *Expression) void {
        switch (expr.*) {
            .Constant, .Var => {},
            .Unary => expr.*.Unary.deinit(),
            .Binary => expr.*.Binary.deinit(),
            .Assignment => expr.*.Assignment.deinit(),
            .Ternary => expr.*.Ternary.deinit(),
        }
    }
};

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

    allocator: Allocator,
    operator: Operator,
    operand: *Expression,
    type: enum { Pre, Post },
    lineIndex: usize,

    pub fn initPost(allocator: Allocator, token: Token, right: Expression) ParsingError!Unary {
        if (!mem.eql(u8, "++", token.symbol) and !mem.eql(u8, "--", token.symbol)) return unexpectedToken(token);

        const operand = allocator.create(Expression) catch allocError();
        operand.* = right;

        const operator: Operator = OperatorMap.get(token.symbol) orelse unreachable;
        return .{ .allocator = allocator, .operator = operator, .operand = operand, .type = .Post, .lineIndex = token.lineIndex };
    }

    pub fn initPre(allocator: Allocator, token: Token, left: Expression) ParsingError!Unary {
        const operand = allocator.create(Expression) catch allocError();
        operand.* = left;

        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);
        return .{ .allocator = allocator, .operator = operator, .operand = operand, .type = .Pre, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: *Unary) void {
        defer self.allocator.destroy(self.operand);

        Expression.deinit(&self.operand.*);
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

    allocator: Allocator,
    operator: Operator,
    left: *Expression,
    right: *Expression,

    pub fn init(allocator: Allocator, token: Token, left: Expression, right: Expression) ParsingError!Binary {
        const operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);

        const leftPtr = allocator.create(Expression) catch allocError();
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocError();
        rightPtr.* = right;

        return .{ .allocator = allocator, .operator = operator, .left = leftPtr, .right = rightPtr };
    }

    pub fn deinit(self: Binary) void {
        defer self.allocator.destroy(self.left);
        defer self.allocator.destroy(self.right);

        Expression.deinit(&self.left.*);
        Expression.deinit(&self.right.*);
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

    allocator: Allocator,
    operator: ?Binary.Operator,
    lhs: *Expression,
    rhs: *Expression,
    lineIndex: usize,

    pub fn init(allocator: Allocator, token: Token, lhs: Expression, rhs: Expression) ParsingError!Assignment {
        const operator = if (mem.eql(u8, "=", token.symbol))
            null
        else
            OperatorMap.get(token.symbol) orelse return unexpectedToken(token);

        const lhsPtr = allocator.create(Expression) catch allocError();
        lhsPtr.* = lhs;

        const rhsPtr = allocator.create(Expression) catch allocError();
        rhsPtr.* = rhs;

        return .{ .allocator = allocator, .operator = operator, .lhs = lhsPtr, .rhs = rhsPtr, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: Assignment) void {
        defer self.allocator.destroy(self.lhs);
        defer self.allocator.destroy(self.rhs);

        Expression.deinit(&self.lhs.*);
        Expression.deinit(&self.rhs.*);
    }

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ParsingError!?Expression {
        const lhs = try parseFactor(allocator, tokens);
        if (lhs != .Var) {
            std.log.err("Expression type {any} is not an assignable lvalue", .{lhs});
            return ParsingError.Lvalue;
        }
        const nextToken = tokens.peek() orelse return unexpectedEOF();
        return if (mem.eql(u8, "=", nextToken.symbol)) blk: {
            const operator = tokens.next() orelse return unexpectedEOF();
            const rhs = try Expression.parse(allocator, tokens, 0);
            break :blk .{ .Assignment = try .init(allocator, operator, lhs, rhs) };
        } else null;
    }
};

pub const Ternary = struct {
    allocator: Allocator,
    condition: *Expression,
    then: *Expression,
    else_: *Expression,

    pub fn init(allocator: Allocator, left: Expression, middle: Expression, right: Expression) ParsingError!Ternary {
        const condition = allocator.create(Expression) catch allocError();
        condition.* = left;

        const then = allocator.create(Expression) catch allocError();
        then.* = middle;

        const else_ = allocator.create(Expression) catch allocError();
        else_.* = right;

        return .{ .allocator = allocator, .condition = condition, .then = then, .else_ = else_ };
    }

    pub fn deinit(self: *Ternary) void {
        defer self.allocator.destroy(self.condition);
        defer self.allocator.destroy(self.then);
        defer self.allocator.destroy(self.else_);

        Expression.deinit(self.condition);
        Expression.deinit(self.then);
        Expression.deinit(self.else_);
    }
};

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) ParsingError!Expression {
    const token = tokens.next() orelse return unexpectedEOF();
    const expr: Expression = switch (token.type) {
        .Constant => .{ .Constant = token.symbol },
        .UnaryOp => blk: { // '~'|'!'|'-'|'++'|'--' <factor>
            const right = try parseFactor(allocator, tokens);
            break :blk .{ .Unary = try Unary.initPre(allocator, token, right) };
        },
        .Identifier => .{ .Var = .{ .name = token.symbol, .lineIndex = token.lineIndex } },
        .OpenParenthesis => blk: { // '(' <expr> ')'
            const expr = try Expression.parse(allocator, tokens, 0);
            const next = tokens.next() orelse return unexpectedEOF();
            if (next.type != .CloseParenthesis) return unexpectedToken(token);
            break :blk expr;
        },
        else => return unexpectedToken(token),
    };

    const nextToken = tokens.peek() orelse return unexpectedEOF();
    if (nextToken.type == .UnaryOp) { // '~'|'!'|'-'|'++'|'--' <factor> '++'|'--'
        return .{ .Unary = try .initPost(allocator, tokens.next().?, expr) };
    }

    return expr;
}

pub fn expect(expected: Token.Type, token: ?Token) ParsingError!void {
    if (token == null) {
        std.log.err("Unexpected end of file", .{});
        return ParsingError.Syntax;
    }

    if (expected != token.?.type) {
        std.log.err("Got unexpected {any} token '{s}'. Expected type {any}", .{ token.?.type, token.?.symbol, expected });
        return ParsingError.Syntax;
    }
}

fn unexpectedEOF() ParsingError {
    std.log.err("Unexpected end of file", .{});
    return ParsingError.EOF;
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}

fn unexpectedToken(token: Token) ParsingError {
    std.log.err("Got unexpected {any} token '{s}'", .{ token.type, token.symbol });
    return ParsingError.Token;
}
