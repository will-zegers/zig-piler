const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log;

const Token = @import("../Lexer/Token.zig");

const common = @import("common.zig");
const ExpectedErrors = common.ExpectedErrors;
const ParserError = common.ParserError;
const Specifiers = common.Specifiers;
const expect = common.expect;

const Type = @import("type.zig").Type;

pub const Declarator = union(enum) {
    Identifier: Identifier,
    Pointer: Pointer,
    Function: Function,

    pub fn parse(allocator: Allocator, tokens: *Token.Iterator) ExpectedErrors!Declarator {
        const token = tokens.next();
        if (mem.eql(u8, "*", token.symbol)) {
            const decl = try allocator.create(Declarator);
            decl.* = try Declarator.parse(allocator, tokens);
            return .{ .Pointer = .{ .decl = decl } };
        }

        var simple: Declarator = undefined;
        if (token.type == .OpenParenthesis) {
            simple = try Declarator.parse(allocator, tokens);
            try expect(.CloseParenthesis, tokens.next());
        } else {
            try expect(.Identifier, token);
            simple = .{ .Identifier = .{ .name = token.symbol } };
        }

        if (isFunType(tokens)) {
            const paramList = try parseParamList(allocator, tokens);
            const decl = try allocator.create(Declarator);
            decl.* = simple;
            return .{ .Function = .{ .decl = decl, .paramInfo = paramList } };
        }

        return simple;
    }

    pub fn deinit(self: Declarator, allocator: Allocator) void {
        switch (self) {
            .Function => self.Function.deinit(allocator),
            .Identifier => {},
            .Pointer => self.Pointer.deinit(allocator),
        }
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
};

const Param = struct {
    type: Type,
    decl: Declarator,
};

const Identifier = struct { name: []const u8 };

const Pointer = struct {
    decl: *Declarator,

    fn init(allocator: Allocator, declarator: Declarator) Allocator.Error!Pointer {
        const decl = try allocator.create(Declarator);
        decl.* = declarator;
        return .{ .decl = decl };
    }

    fn deinit(self: Pointer, allocator: Allocator) void {
        self.decl.deinit(allocator);
        allocator.destroy(self.decl);
    }
};

const Function = struct {
    decl: *Declarator,
    paramInfo: []Param,

    fn init(allocator: Allocator, declarator: Declarator) Allocator.Error!Function {
        const decl = try allocator.create(Declarator);
        decl.* = declarator;
        return .{ .decl = decl };
    }

    fn deinit(self: Function, allocator: Allocator) void {
        for (self.paramInfo) |param| {
            param.decl.deinit(allocator);
        }
        allocator.free(self.paramInfo);

        self.decl.deinit(allocator);
        allocator.destroy(self.decl);
    }
};
