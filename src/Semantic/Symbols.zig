const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const HashMap = std.HashMap;

const Parser = @import("../Parser.zig");
const Type = Parser.Type;

pub const StaticInit = Parser.Constant; // TODO: decouple this from Parser.Constant when they diverge

pub const Static = struct {
    const InitialValueTag = enum { Initial, Tentative, None };
    pub const InitialValue = union(InitialValueTag) {
        Initial: StaticInit,
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
