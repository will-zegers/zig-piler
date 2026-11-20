const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const HashMap = std.HashMap;

const Parser = @import("../Parser.zig");
const Type = Parser.Type;

pub const StaticInit = Parser.Constant; // TODO: decouple this from Parser.Constant when they diverge

pub const Static = struct {
    pub const InitialValue = union(enum) {
        Initial: StaticInit,
        Tentative: void,
        None: void,
    };
    initialValue: InitialValue,
    global: bool,
};

pub const Attrs = union(enum) {
    Fun: struct {
        defined: bool,
        global: bool,
    },
    Local: void,
    Static: Static,
};

pub const Entry = struct {
    type: Type,
    attrs: Attrs,
};

pub const Table = StringHashMap(Entry);
