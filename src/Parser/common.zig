const std = @import("std");
const log = std.log;

const Token = @import("../Lexer.zig").Token;

pub const identifier = []const u8;

// TODO: merge parsing and semantic errors
pub const ParsingError = error{
    DuplicateCase,
    EOF,
    InvalidType,
    InvalidStorageClass,
    Lvalue,
    MaxCaseCount,
    NonConstExpr,
    Syntax,
    Token,
};

pub const TypeTag = enum { Int, Long, FunType };
pub const Type = union(TypeTag) {
    Int: void,
    Long: void,
    FunType: struct {
        params: []*const Type,
        ret: *Type,
    },

    pub fn parse(types: [2]?Type, symbol: []const u8) !Type {
        if (types[1] == null) {
            if (types[0] == null) {
                log.err("Declaration for '{s}' does not name a type", .{symbol});
                return ParsingError.InvalidType;
            }

            switch (types[0].?) {
                .Int => return .Int,
                .Long => return .Long,
                else => {
                    log.err("Invalid type specifier '{any} {any}'", .{ types[0].?, types[1].? });
                    return ParsingError.InvalidType;
                },
            }
        }

        if ((types[0].? == .Int and types[1].? == .Long) or (types[0].? == .Long and types[1].? == .Int)) {
            return .Long;
        }

        log.err("Invalid type specifier '{any} {any}'", .{ types[0].?, types[1].? });
        return ParsingError.InvalidType;
    }

    pub fn equals(self: Type, other: Type) bool {
        return switch (self) {
            .Int => switch (other) {
                .Int => true,
                else => false,
            },
            .Long => switch (other) {
                .Long => true,
                else => false,
            },
            .FunType => switch (other) {
                .FunType => true,
                else => false,
            },
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

        specifiers.type = try Type.parse(types, nextToken.symbol);
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
