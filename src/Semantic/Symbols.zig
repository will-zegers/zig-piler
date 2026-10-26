const std = @import("std");
const StringHashMap = std.StringHashMap;

const TypeTag = enum { Int, FunType };
const Type = union(TypeTag) {
    Int: void,
    FunType: struct {
        type: void,
        nParams: usize,
    },
};

pub const Static = struct {
    const InitialValueTag = enum { Initial, Tentative, None };
    pub const InitialValue = union(InitialValueTag) {
        Initial: struct { int: usize },
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
