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
};

pub const Expression = union(ExpressionTag) {
    Constant: Constant,
    Var: Var,
    Unary: Unary,
    Binary: Binary,
    Assignment: Assignment,

    /// Evaluates expression from left-to-right for arithmetic, or right-to-left for assignment, operators.
    /// This is a recursive descent parser that uses the precedence climbing algorithm.
    pub fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) ParsingError!Expression {
        var left = try parseFactor(allocator, tokens);

        var nextToken = tokens.peek() orelse return unexpectedEOF();
        while (nextToken.associativity != .None and nextToken.precedence >= minPrecedence) {
            const operator = tokens.next() orelse return unexpectedEOF();
            if (nextToken.associativity == .RightToLeft) {
                const right = try parse(allocator, tokens, nextToken.precedence);
                const temp = try Assignment.init(allocator, operator, left, right);
                left = .{ .Assignment = temp };
            } else {
                left = switch (nextToken.type) {
                    .UnaryOp => blk: {
                        const temp = Unary.initPost(allocator, operator, left);
                        break :blk .{ .Unary = temp };
                    },
                    .BinaryOp => blk: {
                        const right = try parse(allocator, tokens, nextToken.precedence + 1);
                        const temp = try Binary.init(allocator, operator, left, right);
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
            .Unary => |*unary| unary.deinit(),
            .Binary => |*binary| binary.deinit(),
            .Assignment => |*assign| assign.deinit(),
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

    pub fn initPost(allocator: Allocator, token: Token, right: Expression) Unary {
        const operand = allocator.create(Expression) catch allocError();
        operand.* = right;

        const operator: Operator = OperatorMap.get(token.symbol) orelse unreachable;
        return .{ .allocator = allocator, .operator = operator, .operand = operand, .type = .Post, .lineIndex = token.lineIndex };
    }

    pub fn initPre(allocator: Allocator, token: Token, left: Expression) Unary {
        const operand = allocator.create(Expression) catch allocError();
        operand.* = left;

        const operator: Operator = OperatorMap.get(token.symbol) orelse unreachable;
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

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) ParsingError!Expression {
    const token = tokens.next() orelse return unexpectedEOF();
    const expr: Expression = switch (token.type) {
        .Constant => .{ .Constant = token.symbol },
        .UnaryOp => blk: {
            const right = try parseFactor(allocator, tokens);
            break :blk .{ .Unary = Unary.initPre(allocator, token, right) };
        },
        .Identifier => .{ .Var = .{ .name = token.symbol, .lineIndex = token.lineIndex } },
        .OpenParenthesis => blk: {
            const expr = try Expression.parse(allocator, tokens, 0);
            const next = tokens.next() orelse return unexpectedEOF();
            if (next.type != .CloseParenthesis) return unexpectedToken(token);
            break :blk expr;
        },
        else => return unexpectedToken(token),
    };

    const nextToken = tokens.peek() orelse return unexpectedEOF();
    if (nextToken.type == .UnaryOp) {
        return .{ .Unary = .initPost(allocator, tokens.next().?, expr) };
    }

    return expr;
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
