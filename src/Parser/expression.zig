const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const Token = @import("../Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const identifier = []const u8;
const int = []const u8;

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
    pub fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) Expression {
        var left = parseFactor(allocator, tokens);

        var nextToken = tokens.peek() orelse unexpectedEOF();
        while (nextToken.associativity != .None and nextToken.precedence >= minPrecedence) {
            const operator = tokens.next() orelse unexpectedEOF();
            if (nextToken.associativity == .Right) {
                const right = parse(allocator, tokens, nextToken.precedence);
                const temp = Assignment.init(allocator, operator, left, right);
                left = .{ .Assignment = temp };
            } else if (nextToken.associativity == .Left) {
                left = switch (nextToken.type) {
                    .UnaryOp => blk: {
                        const temp = Unary.initPost(allocator, operator.symbol, left);
                        break :blk .{ .Unary = temp };
                    },
                    .BinaryOp => blk: {
                        const right = parse(allocator, tokens, nextToken.precedence + 1);
                        const temp = Binary.init(allocator, operator, left, right);
                        break :blk .{ .Binary = temp };
                    },
                    else => unreachable,
                };
            }
            nextToken = tokens.peek() orelse unexpectedEOF();
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

pub const Var = identifier;

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

    pub fn initPost(allocator: Allocator, symbol: []const u8, right: Expression) Unary {
        const operand = allocator.create(Expression) catch allocationError(Unary);
        operand.* = right;

        const operator: Operator = OperatorMap.get(symbol) orelse unreachable;
        return .{ .allocator = allocator, .operator = operator, .operand = operand, .type = .Post };
    }

    pub fn initPre(allocator: Allocator, symbol: []const u8, left: Expression) Unary {
        const operand = allocator.create(Expression) catch allocationError(Unary);
        operand.* = left;

        const operator: Operator = OperatorMap.get(symbol) orelse unreachable;
        return .{ .allocator = allocator, .operator = operator, .operand = operand, .type = .Pre };
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

    pub fn init(allocator: Allocator, token: Token, left: Expression, right: Expression) Binary {
        const operator = OperatorMap.get(token.symbol) orelse unexpectedToken(token);

        const leftPtr = allocator.create(Expression) catch allocationError(Binary);
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocationError(Binary);
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

    pub fn init(allocator: Allocator, token: Token, lhs: Expression, rhs: Expression) Assignment {
        const operator = if (mem.eql(u8, "=", token.symbol))
            null
        else
            OperatorMap.get(token.symbol) orelse unexpectedToken(token);

        const lhsPtr = allocator.create(Expression) catch allocationError(Binary);
        lhsPtr.* = lhs;

        const rhsPtr = allocator.create(Expression) catch allocationError(Binary);
        rhsPtr.* = rhs;

        return .{ .allocator = allocator, .operator = operator, .lhs = lhsPtr, .rhs = rhsPtr };
    }

    pub fn deinit(self: Assignment) void {
        defer self.allocator.destroy(self.lhs);
        defer self.allocator.destroy(self.rhs);

        Expression.deinit(&self.lhs.*);
        Expression.deinit(&self.rhs.*);
    }

    pub fn parse(allocator: Allocator, tokens: *TokenIterator) ?Expression {
        const lhs = parseFactor(allocator, tokens);
        if (lhs != .Var) fatal("Expression type {any} is not an assignable lvalue", .{lhs});
        const nextToken = tokens.peek() orelse unexpectedEOF();
        return if (mem.eql(u8, "=", nextToken.symbol)) blk: {
            const operator = tokens.next() orelse unexpectedEOF();
            const rhs = Expression.parse(allocator, tokens, 0);
            break :blk .{ .Assignment = .init(allocator, operator, lhs, rhs) };
        } else null;
    }
};

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) Expression {
    const token = tokens.next() orelse unexpectedEOF();
    const expr: Expression = switch (token.type) {
        .Constant => .{ .Constant = token.symbol },
        .UnaryOp => blk: {
            const right = parseFactor(allocator, tokens);
            break :blk .{ .Unary = .initPre(allocator, token.symbol, right) };
        },
        .Identifier => .{ .Var = token.symbol },
        .OpenParenthesis => blk: {
            defer {
                const next = tokens.next() orelse unexpectedEOF();
                if (next.type != .CloseParenthesis) unexpectedToken(token);
            }
            const expr = Expression.parse(allocator, tokens, 0);
            break :blk expr;
        },
        else => unexpectedToken(token),
    };

    const nextToken = tokens.peek() orelse unexpectedEOF();
    if (nextToken.type == .UnaryOp) {
        return .{ .Unary = .initPost(allocator, tokens.next().?.symbol, expr) };
    }

    return expr;
}

fn unexpectedEOF() noreturn {
    fatal("Unexpected end of file", .{});
}

fn allocationError(t: type) noreturn {
    fatal("Allocation failed for struct {any}", .{t});
}

fn unexpectedToken(token: Token) noreturn {
    fatal("Got unexpected token {s} of type {any}", .{ token.symbol, token.type });
}
