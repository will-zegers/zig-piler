const std = @import("std");
const StringHashMap = std.StringHashMap;

const FunType = struct {
    type: void,
    nParams: usize,
};

const TypeTag = enum { Int, FunType };
const Type = union(TypeTag) {
    Int: void,
    FunType: FunType,
};

const Fun = struct {
    defined: bool,
    global: bool,
};

pub const Static = struct {
    const Initial = struct { int: usize };

    const InitialValueTag = enum { Initial, Tentative, None };
    pub const InitialValue = union(InitialValueTag) {
        Initial: Initial,
        Tentative: void,
        None: void,
    };
    initialValue: InitialValue,
    global: bool,
};
const Local = void;

const AttrsTag = enum { Fun, Static, Local };
pub const Attrs = union(AttrsTag) {
    Fun: Fun,
    Static: Static,
    Local: void,
};

pub const Entry = struct {
    type: Type,
    attrs: Attrs,
};

pub const Table = StringHashMap(Entry);
