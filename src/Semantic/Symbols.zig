const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const HashMap = std.HashMap;

const Parser = @import("../Parser.zig");
const Type = Parser.Type;

pub const Static = struct {
    const InitialValueTag = enum { Initial, Tentative, None };
    pub const InitialValue = union(InitialValueTag) {
        Initial: Parser.Constant, // TODO: decouple this from Parser.Constant when they diverge
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

pub const Table2 = struct {
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    map: StringHashMap(Entry),
    counter: usize = 0,

    pub fn init(allocator: Allocator) Table {
        var arena: ArenaAllocator = .init(allocator);

        const alloc = arena.allocator();
        const map: StringHashMap(Entry) = .init(alloc);

        return .{ .allocator = alloc, .arena = arena, .map = map };
    }

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    pub fn put(self: *Table, key: []const u8, entry: Entry) !void {
        std.debug.print("{s} {any}\n", .{ key, entry });
        std.debug.print("{any}\n", .{self.map});
        try self.map.put(key, entry);
    }

    pub fn get(self: Table, key: []const u8) ?Entry {
        return self.map.get(key);
    }

    pub fn iterator(self: Table) StringHashMap(Entry).Iterator {
        return self.map.iterator();
    }

    pub fn newVariable(self: *Table, name: []const u8, t: Type) ![]const u8 {
        const newName = self.nextTag(name);
        try self.map.put(name, .{ .type = t, .attrs = .Local });
        return newName;
    }

    pub fn newLabel(self: *Table, name: []const u8, descr: []const u8) ![]const u8 {
        const label = try self.allocator.print("{s}.{s}.{d}", .{ name, descr, self.counter });
        self.counter += 1;
        return label;
    }

    fn nextTag(self: *Table, name: []const u8) ![]const u8 {
        const tag = try self.allocator.print("{s}.{d}", .{ name, self.counter });
        self.counter += 1;
        return tag;
    }
};
