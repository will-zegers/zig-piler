const std = @import("std");
const mem = std.mem;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const Token = @import("../Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const identifier = []const u8;
const int = []const u8;

pub const ExpressionTag = enum {
    Assignment,
    Binary,
    Factor,
};

pub const Expression = union(ExpressionTag) {
    Assignment: Assignment,
    Binary: Binary,
    Factor: Factor,

    /// Evaluates expression from left-to-right with precedence climbing
    pub fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) Expression {
        var left: Expression = .{ .Factor = .factory(allocator, tokens) };

        var nextToken = tokens.peek() orelse unexpectedEOF();
        while (nextToken.type == .BinaryOp and nextToken.precedence >= minPrecedence) {
            if (mem.eql(u8, "=", nextToken.symbol)) {
                _ = tokens.next(); // consome the assignment operator
                const right = parse(allocator, tokens, nextToken.precedence);

                const temp = Assignment.init(allocator, left, right);
                left = .{ .Assignment = temp };
            } else {
                const operator = tokens.next() orelse unexpectedEOF();
                const right = parse(allocator, tokens, nextToken.precedence + 1);

                const temp = Binary.init(allocator, operator, left, right);
                left = .{ .Binary = temp };
            }
            nextToken = tokens.peek() orelse unexpectedEOF();
        }
        return left;
    }

    pub fn deinit(expr: *Expression) void {
        switch (expr.*) {
            .Factor => switch (expr.*.Factor) {
                .Constant, .Var => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => |*binary| binary.deinit(),
            .Assignment => |*assign| assign.deinit(),
        }
    }
};

pub const Binary = struct {
    const BinaryOpMap = std.StaticStringMap(Operator).initComptime(.{
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

    allocator: Allocator,
    operator: Operator,
    left: *Expression,
    right: *Expression,

    pub fn init(allocator: Allocator, token: Token, left: Expression, right: Expression) Binary {
        const operator: Operator = BinaryOpMap.get(token.symbol) orelse unexpectedToken(token);
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

pub const FactorTag = enum {
    Constant,
    Var,
    Unary,
    Parantheses,
};
pub const Factor = union(FactorTag) {
    Constant: Constant,
    Var: Var,
    Unary: Unary,
    Parantheses: Parantheses,

    pub fn factory(allocator: Allocator, tokens: *TokenIterator) Factor {
        const token = tokens.next() orelse unexpectedEOF();
        return switch (token.type) {
            .Constant => .{ .Constant = token.symbol },
            .UnaryOp => .{ .Unary = .init(allocator, token.symbol, tokens) },
            .OpenParenthesis => .{ .Parantheses = .init(allocator, tokens) },
            .Identifier => .{ .Var = token.symbol },
            else => unexpectedToken(token),
        };
    }
};

pub const Constant = int;

pub const Var = identifier;

pub const Unary = struct {
    pub const Operator = enum {
        Complement,
        Negate,
        Not,
    };

    allocator: Allocator,
    operator: Operator,
    factor: *Factor,

    pub fn init(allocator: Allocator, symbol: []const u8, tokens: *TokenIterator) Unary {
        const factor = allocator.create(Factor) catch allocationError(Unary);
        factor.* = Factor.factory(allocator, tokens);

        const operator: Operator = switch (symbol[0]) {
            '~' => .Complement,
            '-' => .Negate,
            '!' => .Not,
            else => unreachable,
        };

        return .{ .allocator = allocator, .operator = operator, .factor = factor };
    }

    pub fn deinit(self: *Unary) void {
        defer self.allocator.destroy(self.factor);

        switch (self.factor.*) {
            .Unary => |*factor| factor.deinit(),
            .Parantheses => |*parantheses| parantheses.deinit(),
            else => {},
        }
    }
};

pub const Parantheses = struct {
    allocator: Allocator,
    expr: *Expression,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Parantheses {
        const expr = allocator.create(Expression) catch allocationError(Parantheses);
        expr.* = Expression.parse(allocator, tokens, 0);

        const token = tokens.next() orelse unexpectedEOF();
        if (token.type != .CloseParenthesis) unexpectedToken(token);

        return .{ .allocator = allocator, .expr = expr };
    }

    pub fn deinit(self: *Parantheses) void {
        defer self.allocator.destroy(self.expr);

        Expression.deinit(&self.expr.*);
    }
};

pub const Assignment = struct {
    allocator: Allocator,
    left: *Expression,
    right: *Expression,

    pub fn init(allocator: Allocator, left: Expression, right: Expression) Assignment {
        const leftPtr = allocator.create(Expression) catch allocationError(Binary);
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocationError(Binary);
        rightPtr.* = right;

        return .{ .allocator = allocator, .left = leftPtr, .right = rightPtr };
    }

    pub fn deinit(self: Assignment) void {
        defer self.allocator.destroy(self.left);
        defer self.allocator.destroy(self.right);

        Expression.deinit(&self.left.*);
        Expression.deinit(&self.right.*);
    }
};

fn unexpectedEOF() noreturn {
    fatal("Unexpected end of file", .{});
}

fn allocationError(t: type) noreturn {
    fatal("Allocation failed for struct {any}", .{t});
}

fn unexpectedToken(token: Token) noreturn {
    fatal("Got unexpected token {s} of type {any}", .{ token.symbol, token.type });
}
