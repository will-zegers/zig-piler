const std = @import("std");
const log = std.log;

const Token = @import("../Lexer.zig").Token;

pub const identifier = []const u8;

pub const ParsingError = error{
    DefaultArgument,
    DuplicateCase,
    EOF,
    ForLoopFunDecl,
    InvalidType,
    InvalidStorageClass,
    InvalidSignage,
    Lvalue,
    MaxCaseCount,
    Syntax,
    Token,
};

pub const TypeTag = enum { Int, Long, FunType, UInt, ULong };
pub const Type = union(TypeTag) {
    const Signage = enum { Signed, Unsigned };

    Int: void,
    Long: void,
    FunType: struct {
        params: []*const Type,
        ret: *Type,
    },
    UInt: void,
    ULong: void,

    pub fn parse(types: [2]?Type, signage: ?Signage, symbol: []const u8) !Type {
        if (types[1] == null) {
            if (types[0] == null) {
                if (signage == null) {
                    log.err("Declaration for '{s}' does not name a type", .{symbol});
                    return ParsingError.InvalidType;
                }
                return if (signage.? == .Unsigned) .UInt else .Int;
            }

            switch (types[0].?) {
                .Int => return if (signage != null and signage.? == .Unsigned) .UInt else .Int,
                .Long => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                else => {
                    log.err("Invalid type specifier '{any} {any}'", .{ types[0].?, types[1].? });
                    return ParsingError.InvalidType;
                },
            }
        }

        // TODO: equals()
        if ((types[0].? == .Int and types[1].? == .Long) or (types[0].? == .Long and types[1].? == .Int)) {
            return if (signage != null and signage.? == .Unsigned) .Long else .Long;
        }

        log.err("Invalid type specifier '{any} {any}'", .{ types[0].?, types[1].? });
        return ParsingError.InvalidType;
    }

    // Helper function since unions can't use comparison operators directly
    pub fn equals(self: Type, other: Type) bool {
        return switch (self) {
            .FunType => other == .FunType,
            .Int => other == .Int,
            .Long => other == .Long,
            .UInt => other == .UInt,
            .ULong => other == .ULong,
        };
    }
};

pub const StorageClass = enum { Extern, Static };

pub const Specifiers = struct {
    lineIndex: usize,
    type: ?Type = null,
    storageClass: ?StorageClass = null,

    pub fn parse(tokens: *Token.Iterator) ParsingError!Specifiers {
        var nextToken = tokens.peek();
        var specifiers: Specifiers = .{ .lineIndex = nextToken.lineIndex };
        var signage: ?Type.Signage = null;

        var typeIndex: usize = 0;
        var types = [2]?Type{ null, null };
        while (true) {
            switch (nextToken.type) {
                .Int, .Long => {
                    if (typeIndex >= types.len) {
                        log.err("Unvalid type specifier '{s}'", .{nextToken.symbol});
                        return ParsingError.InvalidType;
                    }

                    switch (nextToken.type) {
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
                        return ParsingError.InvalidSignage;
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
                        return ParsingError.InvalidStorageClass;
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
        return specifiers;
    }
};

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}

pub fn expect(expected: Token.Type, token: Token) ParsingError!void {
    if (expected != token.type) {
        std.log.err("Got unexpected {any} token '{s}'. Expected type {any}", .{ token.type, token.symbol, expected });
        return ParsingError.Syntax;
    }
}
