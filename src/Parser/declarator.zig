const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log;

const Token = @import("../Lexer/Token.zig");

const common = @import("common.zig");
const Type = common.Type;
const ExpectedErrors = common.ExpectedErrors;
const ParserError = common.ParserError;
const Specifiers = common.Specifiers;
const expect = common.expect;

const DeclaratorTag = enum { Ident, PointerDeclarator, FunDeclarator };
pub const Declarator = union(DeclaratorTag) {
    Ident: Ident,
    PointerDeclarator: PointerDeclarator,
    FunDeclarator: FunDeclarator,

    pub fn parse(allocator: Allocator, tokens: *Token.Iterator) ExpectedErrors!Declarator {
        const token = tokens.next();
        if (mem.eql(u8, "*", token.symbol)) {
            const decl = try allocator.create(Declarator);
            decl.* = try Declarator.parse(allocator, tokens);
            return .{ .PointerDeclarator = .{ .decl = decl } };
        }

        var simple: Declarator = undefined;
        if (token.type == .OpenParenthesis) {
            simple = try Declarator.parse(allocator, tokens);
            try expect(.CloseParenthesis, tokens.next());
        } else {
            try expect(.Identifier, token);
            simple = .{ .Ident = .{ .name = token.symbol } };
        }

        if (isFunType(tokens)) {
            const paramList = try parseParamList(allocator, tokens);
            const decl = try allocator.create(Declarator);
            decl.* = simple;
            return .{ .FunDeclarator = .{ .decl = decl, .paramInfo = paramList } };
        }

        return simple;
    }

    fn isFunType(tokens: *const Token.Iterator) bool {
        return tokens.peek().type == .OpenParenthesis;
    }

    fn parseParamList(allocator: Allocator, tokens: *Token.Iterator) ExpectedErrors![]Param {
        var paramList: ArrayList(Param) = .empty;

        try expect(.OpenParenthesis, tokens.next());

        var nextToken = tokens.peek();
        if (nextToken.type != .Void) {
            while (true) {
                const specifiers = try Specifiers.parse(tokens);
                if (specifiers.storageClass != null) {
                    log.err("Invalid storage class specifier in function declarator", .{});
                    return ParserError.InvalidStorageClass;
                }

                const decl = try Declarator.parse(allocator, tokens);
                try paramList.append(allocator, .{ .type = specifiers.type.?, .decl = decl });

                nextToken = tokens.peek();
                if (nextToken.type == .CloseParenthesis) break;
                try expect(.Comma, tokens.next());
            }
        } else {
            tokens.skip(); // No params, discard the 'void' token
        }

        try expect(.CloseParenthesis, tokens.next());

        return paramList.toOwnedSlice(allocator);
    }

    pub fn deinit(self: Declarator, allocator: Allocator) void {
        switch (self) {
            .Ident => {},
            .FunDeclarator => self.FunDeclarator.deinit(allocator),
            .PointerDeclarator => self.PointerDeclarator.deinit(allocator),
        }
    }
};

const Param = struct {
    type: Type,
    decl: Declarator,
};

const Ident = struct { name: []const u8 };
const PointerDeclarator = struct {
    decl: *Declarator,

    fn init(allocator: Allocator, declarator: Declarator) Allocator.Error!PointerDeclarator {
        const decl = try allocator.create(Declarator);
        decl.* = declarator;
        return .{ .decl = decl };
    }

    fn deinit(self: PointerDeclarator, allocator: Allocator) void {
        allocator.destroy(self.decl);
    }
};
const FunDeclarator = struct {
    decl: *Declarator,
    paramInfo: []Param,

    fn init(allocator: Allocator, declarator: Declarator) Allocator.Error!FunDeclarator {
        const decl = try allocator.create(Declarator);
        decl.* = declarator;
        return .{ .decl = decl };
    }

    fn deinit(self: FunDeclarator, allocator: Allocator) void {
        allocator.destroy(self.decl);
        allocator.free(self.paramInfo);
    }
};
