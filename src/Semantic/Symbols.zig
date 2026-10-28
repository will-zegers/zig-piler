const std = @import("std");
const StringHashMap = std.StringHashMap;

const Parser = @import("../Parser.zig");
const Type = Parser.Type;

pub const Static = struct {
    const InitialValueTag = enum { Initial, Tentative, None };
    pub const InitialValue = union(InitialValueTag) {
        Initial: Parser.Constant,
        Tentative: void,
        None: void,
    };
    initialValue: InitialValue,
    global: bool,
};

const AttrsTag = enum { Fun, Static, Local };
pub const Attrs = union(AttrsTag) {
    Fun: struct {
        defined: bool,
        global: bool,
    },
    Static: Static,
    Local: void,
};

pub const Entry = struct {
    type: Type,
    attrs: Attrs,
};

pub const Table = StringHashMap(Entry);
