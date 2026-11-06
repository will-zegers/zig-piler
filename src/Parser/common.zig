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

pub const TypeTag = enum { Double, Int, Long, FunType, UInt, ULong };
pub const Type = union(TypeTag) {
    const Signage = enum { Signed, Unsigned };

    const Error = error{NonComparable};

    Double: void,
    Int: void,
    Long: void,
    FunType: struct {
        params: []*const Type,
        ret: *Type,
    },
    UInt: void,
    ULong: void,

    fn parse(types: [2]?Type, signage: ?Signage, symbol: []const u8) !Type {
        if (types[1] == null) {
            if (types[0] == null) {
                if (signage == null) {
                    log.err("Declaration for '{s}' does not name a type", .{symbol});
                    return ParsingError.InvalidType;
                }
                return if (signage.? == .Unsigned) .UInt else .Int;
            }

            switch (types[0].?) {
                .Double => return .Double,
                .Int => return if (signage != null and signage.? == .Unsigned) .UInt else .Int,
                .Long => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                else => {
                    log.err("Invalid type specifier '{any}'", .{types[0].?});
                    return ParsingError.InvalidType;
                },
            }
        }

        switch (types[1].?) { // current support for 'long int' and 'int long', both result in type 'long'
            .Double => if (types[0].? == .Long) { // 'double long' and 'long double' also valid
                return .Double;
            } else {
                log.err("Invalid type specifier '{any}' '{any}'", .{ types[0].?, types[1].? });
                return ParsingError.InvalidType;
            },
            .Int => switch (types[0].?) {
                .Double, .Int => {
                    log.err("Invalid type specifier '{any} {any}'", .{ types[0].?, types[1].? });
                    return ParsingError.InvalidType;
                },
                .Long => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                .FunType, .UInt, .ULong => unreachable,
            },
            .Long => switch (types[0].?) {
                .Int => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                .Long => {
                    log.err("Type 'long long' not currently supported", .{});
                    return ParsingError.InvalidType;
                },
                .Double => return .Double,
                .FunType, .UInt, .ULong => unreachable,
            },
            .FunType, .UInt, .ULong => unreachable,
        }
    }

    pub fn signed(self: Type) bool {
        return (self.equals(.Int) or self.equals(.Long));
    }

    pub fn size(self: Type) usize {
        return switch (self) {
            .Int, .UInt => 4,
            .Double, .Long, .ULong => 8,
            .FunType => unreachable,
        };
    }

    // Helper function since unions can't use comparison operators directly
    pub fn equals(self: Type, other: Type) bool {
        return switch (self) {
            .FunType => other == .FunType,
            .Double => other == .Double,
            .Int => other == .Int,
            .Long => other == .Long,
            .UInt => other == .UInt,
            .ULong => other == .ULong,
        };
    }

    /// Follows the Sys V ABI rules to determine a common type: if two types are the
    /// same size but with different signage, prefer the unsigned type; otherwise
    /// prefer the larger type. (And same types obviously prefer that type)
    pub fn getCommon(type1: Type, type2: Type) Type {
        // These two cases will result in an error during semantic type checking,
        // but use return types for now if either is a funtion type
        if (type1 == .FunType) return getCommon(type1.FunType.ret.*, type2);
        if (type2 == .FunType) return getCommon(type1, type2.FunType.ret.*);

        if (type1.equals(.Double) or type2.equals(.Double)) return .Double;
        if (type1.size() > type2.size()) return type1;
        if (type1.size() < type2.size()) return type2;
        if (!type1.signed()) return type1;
        return type2;
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
                .Double, .Int, .Long => {
                    if (typeIndex >= types.len) {
                        log.err("Unvalid type specifier '{s}'", .{nextToken.symbol});
                        return ParsingError.InvalidType;
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
        if (signage != null and specifiers.type.? == .Double) {
            log.err("'double' cannot be signed or unsigned", .{});
            return ParsingError.InvalidSignage;
        }
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
