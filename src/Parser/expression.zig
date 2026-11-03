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

    /// Evaluates expression from left-to-right for arithmetic, or right-to-left for assignment operators.
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
                left = blk: switch (nextToken.type) {
                    .BinaryOp => { // <expr> '+'|'-'|'*'|'/'|'%'|'&'|'|' <expr>
                        const right = try parse(allocator, tokens, nextToken.precedence + 1);
                        const temp = try Binary.parse(allocator, nextToken.lineIndex, nextToken.symbol, left, right);
                        break :blk .{ .Binary = temp };
                    },
                    else => return unexpectedToken(nextToken),
                };
            }
            nextToken = tokens.peek();
        }

        return left;
    }

    pub fn getType(self: Expression) Type {
        return switch (self) {
            .Assignment => self.Assignment.type.?,
            .Binary => self.Binary.type.?,
            .Cast => self.Cast.target.type.?,
            .Constant => switch (self.Constant) {
                .int => .Int,
                .long => .Long,
                .uint => .UInt,
                .ulong => .ULong,
            },
            .FunctionCall => self.FunctionCall.type.?,
            .Ternary => self.Ternary.type.?,
            .Unary => self.Unary.type.?,
            .Var => self.Var.type.?,
        };
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
    const OperatorMap = std.StaticStringMap([]const u8).initComptime(.{
        .{ "+=", "+" },
        .{ "&=", "&" },
        .{ "/=", "/" },
        .{ "%=", "%" },
        .{ "*=", "*" },
        .{ "|=", "|" },
        .{ "<<=", "<<" },
        .{ ">>=", ">>" },
        .{ "-=", "-" },
        .{ "^=", "^" },
    });

    lineIndex: usize,
    type: ?Type = null,
    lhs: *Expression,
    rhs: *Expression,
    isCompound: bool,

    pub fn parse(allocator: Allocator, token: Token, lhs: Expression, rhs: Expression) ParsingError!Assignment {
        const lhsPtr = allocator.create(Expression) catch allocError();
        lhsPtr.* = lhs;

        const rhsPtr = allocator.create(Expression) catch allocError();
        var isCompound: bool = undefined;
        if (OperatorMap.get(token.symbol)) |op| {
            rhsPtr.* = .{ .Binary = try .parse(allocator, token.lineIndex, op, lhs, rhs) };
            isCompound = true;
        } else {
            if (!mem.eql(u8, "=", token.symbol)) {
                log.err("Got unrecognized assignment operator '{s}'", .{token.symbol});
                return ParsingError.Token;
            }

            rhsPtr.* = rhs;
            isCompound = false;
        }

        return .{ .lineIndex = token.lineIndex, .lhs = lhsPtr, .rhs = rhsPtr, .isCompound = isCompound };
    }

    pub fn deinit(self: Assignment, allocator: Allocator) void {
        defer allocator.destroy(self.lhs);
        defer allocator.destroy(self.rhs);

        // If this is a compound assignment, let the underlying binary expression clean up the lhs pointer
        if (!self.isCompound) self.lhs.deinit(allocator);
        self.rhs.deinit(allocator);
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

    pub fn parse(allocator: Allocator, lineIndex: usize, symbol: []const u8, left: Expression, right: Expression) ParsingError!Binary {
        const operator = OperatorMap.get(symbol) orelse {
            log.err("Got unexpected binary operator: {s}", .{symbol});
            return ParsingError.Token;
        };

        const leftPtr = allocator.create(Expression) catch allocError();
        leftPtr.* = left;

        const rightPtr = allocator.create(Expression) catch allocError();
        rightPtr.* = right;

        return .{ .lineIndex = lineIndex, .operator = operator, .left = leftPtr, .right = rightPtr };
    }

    pub fn deinit(self: Binary, allocator: Allocator) void {
        defer allocator.destroy(self.left);
        defer allocator.destroy(self.right);

        self.left.deinit(allocator);
        self.right.deinit(allocator);
    }
};

pub const Cast = struct {
    lineIndex: usize = 0,
    target: Specifiers, // This will get type-checked during semantic analysis, which will forbid storage classes
    exp: *Expression,

    pub fn parse(allocator: Allocator, tokens: *Token.Iterator) ParsingError!Cast {
        try expect(.OpenParenthesis, tokens.next());
        const target = try Specifiers.parse(tokens);
        if (target.storageClass != null) {
            log.err("Invalid storage class specifier in function declarator", .{});
            return ParsingError.InvalidStorageClass;
        }
        try expect(.CloseParenthesis, tokens.next());

        const exp = allocator.create(Expression) catch allocError();
        exp.* = try parseFactor(allocator, tokens);

        return .{ .lineIndex = target.lineIndex, .target = target, .exp = exp };
    }

    pub fn to(allocator: Allocator, exp: *const Expression, toType: Type) Cast {
        const inner = allocator.create(Expression) catch allocError();
        inner.* = exp.*;

        const out: Cast = .{
            .lineIndex = 0,
            .target = .{ .lineIndex = 0, .type = toType },
            .exp = inner,
        };

        return out;
    }

    pub fn deinit(self: *Cast, allocator: Allocator) void {
        self.exp.deinit(allocator);
        allocator.destroy(self.exp);
    }
};

const ConstantTag = enum { int, long, uint, ulong };
pub const Constant = union(ConstantTag) {
    int: i32,
    long: i64,
    uint: u32,
    ulong: u64,

    pub fn parse(token: Token) ParsingError!Constant {
        var valueStr = mem.trimEnd(u8, token.symbol, "Ll"); // ...l?
        if (valueStr.len != token.symbol.len) { // explicit 'long'
            const longValueStr = mem.trimEnd(u8, valueStr, "Uu"); // ...ul?
            if (longValueStr.len != valueStr.len) { // explicit 'long unsigned'
                const ulong = std.fmt.parseInt(u64, longValueStr, 10) catch |err| return parseError(err, token.symbol);
                return .{ .ulong = ulong };
            } else { // explicit 'long', implicit 'signed'
                const long = std.fmt.parseInt(i64, longValueStr, 10) catch |err| return parseError(err, token.symbol);
                return .{ .long = long };
            }
        } else { // check for alternate ordering, i.e. 'ul', 'Ul, 'UL'
            valueStr = mem.trimEnd(u8, token.symbol, "Uu"); // ...u?
            if (valueStr.len != token.symbol.len) { // explicit 'unsigned'
                const unsignedValueStr = mem.trimEnd(u8, valueStr, "Ll"); // ...lu?
                if (valueStr.len != token.symbol.len) { // explicit 'unsigned long'
                    const ulong = std.fmt.parseInt(u64, unsignedValueStr, 10) catch |err| return parseError(err, token.symbol);
                    return .{ .ulong = ulong };
                } else { // explicit 'unsigned', implicit 'long' unless it can fit into 'int'
                    const ulong = std.fmt.parseInt(u64, valueStr, 10) catch |err| return parseError(err, token.symbol);
                    if (ulong > math.maxInt(u32)) {
                        return .{ .ulong = ulong };
                    }

                    const uint: u32 = @intCast(ulong);
                    return .{ .uint = uint };
                }
            } else { // 'implicit 'signed long' unless it will fit as 'unsigned int'
                const signedValue = std.fmt.parseInt(i64, valueStr, 10) catch |err| return parseError(err, token.symbol);
                if (signedValue > math.maxInt(i32)) {
                    return .{ .long = signedValue };
                }

                const int: i32 = @intCast(signedValue);
                return .{ .int = int };
            }
        }
    }

    fn parseError(err: error{ InvalidCharacter, Overflow }, symbol: []const u8) ParsingError {
        switch (err) {
            error.Overflow => {
                const value = mem.trim(u8, symbol, "LlUu");
                log.err("Numeric constant '{s}' exceeds capacity of long", .{value});
            },
            error.InvalidCharacter => log.err("Could not parse numeric constant '{s}'", .{symbol}),
        }
        return ParsingError.Token;
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
            arg.deinit(allocator);
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
    thenExpr: *Expression,
    elseExpr: *Expression,

    pub fn parse(allocator: Allocator, left: Expression, middle: Expression, right: Expression) ParsingError!Ternary {
        const condition = allocator.create(Expression) catch allocError();
        condition.* = left;

        const thenExpr = allocator.create(Expression) catch allocError();
        thenExpr.* = middle;

        const elseExpr = allocator.create(Expression) catch allocError();
        elseExpr.* = right;

        return .{ .condition = condition, .thenExpr = thenExpr, .elseExpr = elseExpr };
    }

    pub fn deinit(self: *Ternary, allocator: Allocator) void {
        defer allocator.destroy(self.condition);
        defer allocator.destroy(self.thenExpr);
        defer allocator.destroy(self.elseExpr);

        self.condition.deinit(allocator);
        self.thenExpr.deinit(allocator);
        self.elseExpr.deinit(allocator);
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

    pub fn pre(allocator: Allocator, token: Token, rhs: Expression) ParsingError!Expression {
        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);

        const operand = allocator.create(Expression) catch allocError();
        operand.* = rhs;
        return .{ .Unary = .{
            .operator = operator,
            .operand = operand,
            .order = .Pre,
            .lineIndex = token.lineIndex,
        } };
    }

    pub fn post(allocator: Allocator, token: Token, lhs: Expression) ParsingError!Expression {
        const operator: Operator = OperatorMap.get(token.symbol) orelse return unexpectedToken(token);
        if (operator != .Dec and operator != .Inc) {
            log.err("'{s}' cannot be used as a post-fix operator", .{token.symbol});
            return ParsingError.Token;
        }

        const operand = allocator.create(Expression) catch allocError();
        operand.* = lhs;
        return .{ .Unary = .{
            .operator = operator,
            .operand = operand,
            .order = .Post,
            .lineIndex = token.lineIndex,
        } };
    }

    pub fn deinit(self: *Unary, allocator: Allocator) void {
        defer allocator.destroy(self.operand);

        self.operand.deinit(allocator);
    }
};

pub const Var = struct {
    type: ?Type = null,
    name: identifier,
    lineIndex: usize,
};

fn parseFactor(allocator: Allocator, tokens: *TokenIterator) ParsingError!Expression {
    const token = tokens.next();
    var expr: Expression = blk: switch (token.type) {
        .Constant => .{ .Constant = try .parse(token) },
        .UnaryOp => { // '~'|'!'|'-'|'++'|'--' <factor>
            const right = try parseFactor(allocator, tokens);
            break :blk try Unary.pre(allocator, token, right);
        },
        .Identifier => {
            const nextToken = tokens.peek();
            if (nextToken.type == .OpenParenthesis) { // check if this a function call
                tokens.rewind(); // back up to process all parts of the function call
                break :blk .{ .FunctionCall = try .parse(allocator, tokens) };
            } else { // otherwise it's just a plain variable
                break :blk .{ .Var = .{ .name = token.symbol, .lineIndex = token.lineIndex } };
            }
        },
        .OpenParenthesis => { // '(' <expr> ')'
            const nextToken = tokens.peek();
            switch (nextToken.type) {
                .Int, .Long, .Signed, .Unsigned => {
                    tokens.rewind();
                    break :blk .{ .Cast = try Cast.parse(allocator, tokens) };
                },
                else => {
                    const expr: Expression = try .parse(allocator, tokens, 0);
                    try expect(.CloseParenthesis, tokens.next());
                    break :blk expr;
                },
            }
        },
        else => return unexpectedToken(token),
    };

    var nextToken = tokens.peek();
    while (nextToken.type == .UnaryOp) { // check for postfix operators
        expr = try Unary.post(allocator, tokens.next(), expr);
        nextToken = tokens.peek();
    }

    return expr;
}

fn unexpectedToken(token: Token) ParsingError {
    log.err("Got unexpected {any} token '{s}'", .{ token.type, token.symbol });
    return ParsingError.Token;
}
