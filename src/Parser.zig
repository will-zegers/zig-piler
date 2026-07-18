const std = @import("std");
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

const Parser = @This();

pub const AST = Program;

pub fn parse(allocator: Allocator, tokens: []Token) AST {
    var tokenIter = Token.iterate(tokens);

    const ast = Program.init(allocator, &tokenIter);
    if (tokenIter.next()) |token| {
        fatal("Unexpected token(s) at end of file: {s}", .{token.symbol});
    }

    return ast;
}

pub const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Program {
        return .{ .allocator = allocator, .function = .init(allocator, tokens) };
    }

    pub fn deinit(self: *Program) void {
        self.function.deinit();
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: []const u8,
    body: Statement,

    pub fn init(allocator: Allocator, tokens: *TokenIterator) Function {
        expect(.Int, tokens.next());

        const name = tokens.next();
        expect(.Identifier, name);

        expect(.OpenParenthesis, tokens.next());
        expect(.Void, tokens.next());
        expect(.CloseParenthesis, tokens.next());

        expect(.OpenBrace, tokens.next());
        const body = Statement.Return(allocator, tokens);
        expect(.CloseBrace, tokens.next());

        return .{ .allocator = allocator, .name = name.?.symbol, .body = body };
    }

    pub fn deinit(self: *Function) void {
        self.body.deinit();
    }
};

pub const Statement = struct {
    const Tag = enum {
        Return,
    };

    allocator: Allocator,
    expr: Expression,
    tag: Tag,

    pub fn Return(allocator: Allocator, tokens: *TokenIterator) Statement {
        expect(.Return, tokens.next());
        const expr = Expression.parse(allocator, tokens, 0);
        expect(.Semicolon, tokens.next());

        return .{ .allocator = allocator, .expr = expr, .tag = .Return };
    }

    pub fn deinit(self: *Statement) void {
        switch (self.expr) {
            .Factor => switch (self.expr.Factor) {
                .Constant => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => |*binary| binary.deinit(),
        }
    }
};

pub const ExpressionTag = enum {
    Binary,
    Factor,
};
pub const Expression = union(ExpressionTag) {
    Binary: Binary,
    Factor: Factor,

    fn parse(allocator: Allocator, tokens: *TokenIterator, minPrecedence: usize) Expression {
        var left: Expression = .{ .Factor = Factor.factory(allocator, tokens) };

        var nextToken = tokens.peek() orelse unexpectedEOF();
        while (nextToken.type == .BinaryOp and nextToken.precedence >= minPrecedence) {
            const operator = tokens.next() orelse unexpectedEOF();
            const right = Expression.parse(allocator, tokens, nextToken.precedence + 1);

            const temp = Binary.init(allocator, operator, left, right);
            left = .{ .Binary = temp };

            nextToken = tokens.peek() orelse unexpectedEOF();
        }
        return left;
    }
};

pub const Binary = struct {
    pub const Operator = enum {
        Add,
        And,
        Div,
        Mod,
        Mul,
        Or,
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
        const operator: Operator = switch (token.symbol[0]) {
            '&' => .And,
            '+' => .Add,
            '/' => .Div,
            '%' => .Mod,
            '*' => .Mul,
            '|' => .Or,
            '<' => .SAL,
            '>' => .SAR,
            '-' => .Sub,
            '^' => .Xor,
            else => unreachable,
        };
        const leftPtr = allocator.create(Expression) catch allocationError(Binary);
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocationError(Binary);
        rightPtr.* = right;

        return .{ .allocator = allocator, .operator = operator, .left = leftPtr, .right = rightPtr };
    }

    pub fn deinit(self: Binary) void {
        defer self.allocator.destroy(self.left);
        defer self.allocator.destroy(self.right);

        switch (self.left.*) {
            .Factor => switch (self.left.*.Factor) {
                .Constant => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => |*binary| binary.deinit(),
        }

        switch (self.right.*) {
            .Factor => switch (self.right.*.Factor) {
                .Constant => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => |*binary| binary.deinit(),
        }
    }
};

pub const FactorTag = enum {
    Constant,
    Unary,
    Parantheses,
};
pub const Factor = union(FactorTag) {
    Constant: Constant,
    Unary: Unary,
    Parantheses: Parantheses,

    fn factory(allocator: Allocator, tokens: *TokenIterator) Factor {
        const token = tokens.next() orelse unexpectedEOF();
        return switch (token.type) {
            .Constant => .{ .Constant = Constant.init(token.symbol) },
            .UnaryOp => .{ .Unary = Unary.init(allocator, token.symbol, tokens) },
            .OpenParenthesis => .{ .Parantheses = Parantheses.init(allocator, tokens) },
            else => fatal("Unexpected factor at '{s}'", .{token.symbol}),
        };
    }
};

pub const Constant = struct {
    int: []const u8,

    pub fn init(int: []const u8) Constant {
        return .{ .int = int };
    }

    pub fn deinit(_: Constant) void {
        return;
    }
};

pub const Unary = struct {
    pub const Operator = enum {
        Complement,
        Negate,
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
        expect(.CloseParenthesis, tokens.next());

        return .{ .allocator = allocator, .expr = expr };
    }

    pub fn deinit(self: *Parantheses) void {
        defer self.allocator.destroy(self.expr);

        switch (self.expr.*) {
            .Factor => switch (self.expr.*.Factor) {
                .Constant => {},
                .Unary => |*unary| unary.deinit(),
                .Parantheses => |*parantheses| parantheses.deinit(),
            },
            .Binary => self.expr.*.Binary.deinit(),
        }
    }
};

fn expect(expected: Token.Type, token: ?Token) void {
    if (token == null) {
        unexpectedEOF();
    }

    if (expected != token.?.type) {
        fatal("Got unexpected token {s} of type {any}; expected type {any}", .{ token.?.symbol, token.?.type, expected });
    }
}

fn unexpectedEOF() noreturn {
    fatal("Unexpected end of file", .{});
}

fn allocationError(t: type) noreturn {
    fatal("Allocation failed for struct {any}", .{t});
}
