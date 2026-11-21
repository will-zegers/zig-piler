const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const common = @import("common.zig");
const ParserError = common.ParserError;

pub const Type = union(enum) {
    pub const Signage = enum { Signed, Unsigned };

    const Error = error{NonComparable};

    Double: void,
    Int: void,
    Long: void,
    FunType: struct {
        params: []*Type,
        ret: *Type,
    },
    Pointer: struct {
        referenced: *Type,
    },
    UInt: void,
    ULong: void,

    pub fn parse(types: [2]?Type, signage: ?Signage, symbol: []const u8) !Type {
        if (types[1] == null) {
            if (types[0] == null) {
                if (signage == null) {
                    log.err("Declaration for '{s}' does not name a type", .{symbol});
                    return ParserError.InvalidType;
                }
                return if (signage.? == .Unsigned) .UInt else .Int;
            }

            switch (types[0].?) {
                .Double => return .Double,
                .Int => return if (signage != null and signage.? == .Unsigned) .UInt else .Int,
                .Long => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                else => {
                    log.err("Invalid type specifier '{any}'", .{types[0].?});
                    return ParserError.InvalidType;
                },
            }
        }

        switch (types[1].?) { // current support for 'long int' and 'int long', both result in type 'long'
            .Double => if (types[0].? == .Long) { // 'double long' and 'long double' also valid
                return .Double;
            } else {
                log.err("Invalid type specifier '{any}' '{any}'", .{ types[0].?, types[1].? });
                return ParserError.InvalidType;
            },
            .Int => switch (types[0].?) {
                .Double, .Int => {
                    log.err("Invalid type specifier '{any} {any}'", .{ types[0].?, types[1].? });
                    return ParserError.InvalidType;
                },
                .Long => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                .FunType, .UInt, .ULong => unreachable,
                .Pointer => unreachable,
            },
            .Long => switch (types[0].?) {
                .Int => return if (signage != null and signage.? == .Unsigned) .ULong else .Long,
                .Long => {
                    log.err("Type 'long long' not currently supported", .{});
                    return ParserError.InvalidType;
                },
                .Double => return .Double,
                .FunType, .Pointer, .UInt, .ULong => unreachable,
            },
            .FunType, .Pointer, .UInt, .ULong => unreachable,
        }
    }

    pub fn deinit(self: Type, allocator: Allocator) void {
        switch (self) {
            .FunType => {
                for (self.FunType.params) |param| {
                    param.deinit(allocator);
                    allocator.destroy(param);
                }
                allocator.free(self.FunType.params);

                self.FunType.ret.*.deinit(allocator);
                allocator.destroy(self.FunType.ret);
            },
            .Pointer => {
                self.Pointer.referenced.*.deinit(allocator);
                allocator.destroy(self.Pointer.referenced);
            },
            else => {},
        }
    }

    pub fn isSignedInteger(self: Type) bool {
        return (self.equals(.Int) or self.equals(.Long));
    }

    pub fn size(self: Type) usize {
        return switch (self) {
            .Int, .UInt => 4,
            .Double, .Long, .ULong => 8,
            .FunType, .Pointer => unreachable,
        };
    }

    // Helper function since unions can't use comparison operators directly
    pub fn equals(self: Type, other: Type) bool {
        return switch (self) {
            .FunType => other == .FunType,
            .Double => other == .Double,
            .Int => other == .Int,
            .Long => other == .Long,
            .Pointer => other == .Pointer,
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
        if (!type1.isSignedInteger()) return type1;
        return type2;
    }
};
