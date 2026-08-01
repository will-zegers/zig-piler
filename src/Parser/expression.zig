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
    Constant,
    Unary,
    Var,
};

pub const Expression = union(ExpressionTag) {
    Assignment: Assignment,
    Binary: Binary,
    Constant: Constant,
    Unary: Unary,
    Var: Var,

    /// Evaluates expression from left-to-right for arithmetic, or right-to-left for assignment, operators.
    /// This is a recursive descent parser that uses the precedence climbing algorithm.
    pub fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) Expression {
        var left = parseFactor(allocator, tokens);

        var nextToken = tokens.peek() orelse unexpectedEOF();
        while (nextToken.type == .BinaryOp and nextToken.precedence >= minPrecedence) {
            if (mem.eql(u8, "=", nextToken.symbol)) {
                tokens.skip(); // consome the assignment operator
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
    };

    allocator: Allocator,
    operator: Operator,
    operand: *Expression,

    pub fn init(allocator: Allocator, symbol: []const u8, tokens: *TokenIterator) Unary {
        const operand = allocator.create(Expression) catch allocationError(Unary);
        operand.* = parseFactor(allocator, tokens);

        const operator: Operator = switch (symbol[0]) {
            '~' => .Complement,
            '-' => .Negate,
            '!' => .Not,
            else => unreachable,
        };

        return .{ .allocator = allocator, .operator = operator, .operand = operand };
    }

    pub fn deinit(self: *Unary) void {
        defer self.allocator.destroy(self.operand);

        Expression.deinit(&self.operand.*);
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

pub const Assignment = struct {
    allocator: Allocator,
    lhs: *Expression,
    rhs: *Expression,

    pub fn init(allocator: Allocator, lhs: Expression, rhs: Expression) Assignment {
        const lhsPtr = allocator.create(Expression) catch allocationError(Binary);
        lhsPtr.* = lhs;

        const rhsPtr = allocator.create(Expression) catch allocationError(Binary);
        rhsPtr.* = rhs;

        return .{ .allocator = allocator, .lhs = lhsPtr, .rhs = rhsPtr };
    }

    pub fn deinit(self: Assignment) void {
        defer self.allocator.destroy(self.lhs);
        defer self.allocator.destroy(self.rhs);

        Expression.deinit(&self.lhs.*);
        Expression.deinit(&self.rhs.*);
    }
};

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) Expression {
    const token = tokens.next() orelse unexpectedEOF();
    return switch (token.type) {
        .Constant => .{ .Constant = token.symbol },
        .UnaryOp => .{ .Unary = .init(allocator, token.symbol, tokens) },
        .Identifier => .{ .Var = token.symbol },
        .OpenParenthesis => blk: {
            defer {
                const next = tokens.next() orelse unexpectedEOF();
                if (next.type != .CloseParenthesis) unexpectedToken(token);
            }
            break :blk Expression.parse(allocator, tokens, 0);
        },
        else => unexpectedToken(token),
    };
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
