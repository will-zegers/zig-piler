const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const Token = @import("../Lexer.zig").Token;

const Type = @import("type.zig").Type;

pub const identifier = []const u8;

pub const ExpectedErrors = Allocator.Error || ParserError;

pub const ParserError = error{
    AdditionalFunctionDerivation,
    DefaultArgument,
    DuplicateCase,
    EOF,
    ForLoopFunDecl,
    FunctionPointerInParams,
    InvalidType,
    InvalidStorageClass,
    InvalidSignage,
    Lvalue,
    MaxCaseCount,
    Syntax,
    Token,
};

pub const StorageClass = enum { Extern, Static };

pub const Specifiers = struct {
    lineIndex: usize,
    type: ?Type = null,
    storageClass: ?StorageClass = null,

    pub fn parse(tokens: *Token.Iterator) ParserError!Specifiers {
        var nextToken = tokens.peek();
        var specifiers: Specifiers = .{ .lineIndex = nextToken.lineIndex };
        var signage: ?Type.Signage = null;

        var typeIndex: usize = 0;
        var types = [2]?Type{ null, null };
        while (true) {
            switch (nextToken.type) {
                .Double, .Int, .Long => {
                    if (typeIndex >= types.len) {
                        log.err("Unvalid type specifier '{s}'", .{nextToken.symbol});
                        return ParserError.InvalidType;
                    }

                    switch (nextToken.type) {
                        .Double => types[typeIndex] = .Double,
                        .Int => types[typeIndex] = .Int,
                        .Long => types[typeIndex] = .Long,
                        else => unreachable,
                    }
                    tokens.skip();
                    typeIndex += 1;
                },
                .Signed, .Unsigned => {
                    if (signage != null) {
                        log.err("Cannot combine with previous '{s}' declaration specifier", .{@tagName(signage.?)});
                        return ParserError.InvalidSignage;
                    }
                    signage = switch (nextToken.type) {
                        // note: different enums
                        // Token.Type => Type.Signage
                        .Signed => .Signed,
                        .Unsigned => .Unsigned,
                        else => unreachable,
                    };
                    tokens.skip();
                },
                .Extern, .Static => {
                    if (specifiers.storageClass != null) {
                        log.err("Invalid or duplicate storage class '{s}'", .{nextToken.symbol});
                        return ParserError.InvalidStorageClass;
                    }

                    switch (nextToken.type) {
                        .Static => specifiers.storageClass = .Static,
                        .Extern => specifiers.storageClass = .Extern,
                        else => unreachable,
                    }
                    tokens.skip();
                },
                else => break,
            }
            nextToken = tokens.peek();
        }

        specifiers.type = try Type.parse(types, signage, nextToken.symbol);
        if (signage != null and specifiers.type.? == .Double) {
            log.err("'double' cannot be signed or unsigned", .{});
            return ParserError.InvalidSignage;
        }
        return specifiers;
    }
};

pub fn expect(expected: Token.Type, token: Token) ParserError!void {
    if (expected != token.type) {
        std.log.err("Got unexpected {any} token '{s}'. Expected type {any}", .{ token.type, token.symbol, expected });
        return ParserError.Syntax;
    }
}
