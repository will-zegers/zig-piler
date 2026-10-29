const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log;
const math = std.math;

const Token = @import("../Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const common = @import("common.zig");
const ParsingError = common.ParsingError;
const Specifiers = common.Specifiers;
const Type = common.Type;
const allocError = common.allocError;
const expect = common.expect;
const identifier = common.identifier;

pub const ExpressionTag = enum {
    Assignment,
    Binary,
    Cast,
    Constant,
    FunctionCall,
    Ternary,
    Unary,
    Var,
};
pub const Expression = union(ExpressionTag) {
    Assignment: Assignment,
    Binary: Binary,
    Cast: Cast,
    Constant: Constant,
    FunctionCall: FunctionCall,
    Ternary: Ternary,
    Unary: Unary,
    Var: Var,

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

                        const temp = try Ternary.parse(allocator, left, middle, right);
                        break :blk .{ .Ternary = temp };
                    },
                    .BinaryOp => { // <expr> '='|'+='|'-='|'*='|'/='|'%='|'&='|'|=' <expr>
                        const right = try parse(allocator, tokens, nextToken.precedence);
                        const temp = try Assignment.parse(allocator, nextToken, left, right);
                        break :blk .{ .Assignment = temp };
                    },
                    else => return unexpectedToken(nextToken),
                };
            } else {
                left = switch (nextToken.type) {
                    .UnaryOp => blk: { // <factor> '++'|'--'
                        const temp = try Unary.post(allocator, nextToken, left);
                        break :blk .{ .Unary = temp };
                    },
                    .BinaryOp => blk: { // <expr> '+'|'-'|'*'|'/'|'%'|'&'|'|' <expr>
                        const right = try parse(allocator, tokens, nextToken.precedence + 1);
                        const temp = try Binary.parse(allocator, nextToken, left, right);
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
            .Assignment => expr.Assignment.deinit(allocator),
            .Binary => expr.Binary.deinit(allocator),
            .Cast => expr.Cast.deinit(allocator),
            .Constant, .Var => {},
            .FunctionCall => expr.FunctionCall.deinit(allocator),
            .Ternary => expr.Ternary.deinit(allocator),
            .Unary => expr.Unary.deinit(allocator),
        }
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

    lineIndex: usize,
    type: ?Type = null,
    operator: ?Binary.Operator,
    lhs: *Expression,
    rhs: *Expression,

    pub fn parse(allocator: Allocator, operator: Token, lhs: Expression, rhs: Expression) ParsingError!Assignment {
        const op = if (mem.eql(u8, "=", operator.symbol))
            null
        else
            OperatorMap.get(operator.symbol);

        const lhsPtr = allocator.create(Expression) catch allocError();
        lhsPtr.* = lhs;

        const rhsPtr = allocator.create(Expression) catch allocError();
        rhsPtr.* = rhs;

        return .{ .lineIndex = operator.lineIndex, .operator = op, .lhs = lhsPtr, .rhs = rhsPtr };
    }

    pub fn deinit(self: Assignment, allocator: Allocator) void {
        defer allocator.destroy(self.lhs);
        defer allocator.destroy(self.rhs);

        Expression.deinit(self.lhs, allocator);
        Expression.deinit(self.rhs, allocator);
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

    lineIndex: usize,
    type: ?Type = null,
    operator: Operator,
    left: *Expression,
    right: *Expression,

    pub fn parse(allocator: Allocator, token: Token, left: Expression, right: Expression) ParsingError!Binary {
        const operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);

        const leftPtr = allocator.create(Expression) catch allocError();
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocError();
        rightPtr.* = right;

        return .{ .lineIndex = token.lineIndex, .operator = operator, .left = leftPtr, .right = rightPtr };
    }

    pub fn deinit(self: Binary, allocator: Allocator) void {
        defer allocator.destroy(self.left);
        defer allocator.destroy(self.right);

        Expression.deinit(self.left, allocator);
        Expression.deinit(self.right, allocator);
    }
};

pub const Cast = struct {
    lineIndex: usize = 0,
    target: Specifiers, // This will get type-checked during semantic analysis, which will forbid storage classes
    exp: *Expression,
    needsDealloc: bool = false,

    pub fn parse(allocator: Allocator, tokens: *Token.Iterator) ParsingError!Cast {
        try expect(.OpenParenthesis, tokens.next());
        const target = try Specifiers.parse(tokens);
        try expect(.CloseParenthesis, tokens.next());

        const exp = allocator.create(Expression) catch allocError();
        exp.* = try parseFactor(allocator, tokens);

        return .{ .lineIndex = target.lineIndex, .target = target, .exp = exp, .needsDealloc = true };
    }

    pub fn to(exp: *const Expression, toType: Type) Cast {
        return .{
            .lineIndex = 0,
            .target = .{ .lineIndex = 0, .type = toType },
            .exp = @constCast(exp),
        };
    }

    pub fn deinit(self: *Cast, allocator: Allocator) void {
        if (self.needsDealloc) allocator.destroy(self.exp);
    }
};

const ConstantTag = enum { int, long };
pub const Constant = union(ConstantTag) {
    int: i32,
    long: i64,

    pub fn parse(token: Token) ParsingError!Constant {
        const num = mem.trimEnd(u8, token.symbol, "Ll");
        const longValue = std.fmt.parseInt(i64, num, 10) catch |err| {
            switch (err) {
                error.Overflow => log.err("Numeric constant '{s}' exceeds capacity of long", .{num}),
                error.InvalidCharacter => log.err("Could not parse numeric constant '{s}'", .{token.symbol}),
            }
            return ParsingError.Token;
        };

        if (longValue < math.pow(i64, 2, 31) - 1) {
            const intValue = std.fmt.parseInt(i32, num, 10) catch unreachable;
            return .{ .int = intValue };
        }

        return .{ .long = longValue };
    }
};

pub const FunctionCall = struct {
    lineIndex: usize,
    type: ?Type = null,
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
        var args: ArrayList(Expression) = .empty;

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

pub const Ternary = struct {
    type: ?Type = null,
    condition: *Expression,
    thenStmt: *Expression,
    elseStmt: *Expression,

    pub fn parse(allocator: Allocator, left: Expression, middle: Expression, right: Expression) ParsingError!Ternary {
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

    lineIndex: usize,
    type: ?Type = null,
    operator: Operator,
    operand: *Expression,
    order: enum { Pre, Post },

    pub fn pre(allocator: Allocator, token: Token, left: Expression) ParsingError!Unary {
        const operand = allocator.create(Expression) catch allocError();
        operand.* = left;

        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);
        return .{ .operator = operator, .operand = operand, .order = .Pre, .lineIndex = token.lineIndex };
    }

    pub fn post(allocator: Allocator, token: Token, right: Expression) ParsingError!Unary {
        if (!mem.eql(u8, "++", token.symbol) and !mem.eql(u8, "--", token.symbol)) return unexpectedToken(token);

        const operand = allocator.create(Expression) catch allocError();
        operand.* = right;

        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);
        return .{ .operator = operator, .operand = operand, .order = .Post, .lineIndex = token.lineIndex };
    }

    pub fn deinit(self: *Unary, allocator: Allocator) void {
        defer allocator.destroy(self.operand);

        Expression.deinit(self.operand, allocator);
    }
};

pub const Var = struct {
    type: ?Type = null,
    name: identifier,
    lineIndex: usize,
};

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) ParsingError!Expression {
    const token = tokens.next();
    const expr: Expression = switch (token.type) {
        .Constant => .{ .Constant = try .parse(token) },
        .UnaryOp => blk: { // '~'|'!'|'-'|'++'|'--' <factor>
            const right = try parseFactor(allocator, tokens);
            break :blk .{ .Unary = try Unary.pre(allocator, token, right) };
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
            const nextToken = tokens.peek();
            if (nextToken.type == .Int or nextToken.type == .Long) {
                tokens.rewind();
                break :blk .{ .Cast = try Cast.parse(allocator, tokens) };
            } else {
                const expr = try Expression.parse(allocator, tokens, 0);
                const next = tokens.next();
                if (next.type != .CloseParenthesis) return unexpectedToken(token);
                break :blk expr;
            }
        },
        else => return unexpectedToken(token),
    };

    const nextToken = tokens.peek();
    if (nextToken.type == .UnaryOp) { // '~'|'!'|'-'|'++'|'--' <factor> '++'|'--'
        return .{ .Unary = try .post(allocator, tokens.next(), expr) };
    }

    return expr;
}

fn unexpectedToken(token: Token) ParsingError {
    log.err("Got unexpected {any} token '{s}'", .{ token.type, token.symbol });
    return ParsingError.Token;
}
