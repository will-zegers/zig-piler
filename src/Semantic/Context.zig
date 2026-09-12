const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Switch = @import("../Parser.zig").Switch;

const Context = @This();

const Entry = struct {
    unique: []const u8,
    fromCurrentScope: bool = true,
    hasLinkage: bool = false,
};

const IdentifierMap = std.StringHashMap(Entry);

pub const GLOBAL_TAG = "_global";
const ScopeType = enum {
    Global,
    Function,
    Block,
    Loop,
    Switch,
};

pub const Scope = struct {
    type: ScopeType,
    identifiers: IdentifierMap,
    tag: []const u8,
};

allocator: Allocator,
labels: IdentifierMap,
scopeStack: ArrayList(Scope),
switchTags: std.StringHashMap(*Switch),
function: ?[]const u8 = null,
counter: usize = 0,

pub fn init(allocator: Allocator) Context {
    var scopeStack: ArrayList(Scope) = .empty;
    scopeStack.append(allocator, .{
        .type = .Block,
        .identifiers = .init(allocator),
        .tag = GLOBAL_TAG,
    }) catch allocError();

    return .{ .allocator = allocator, .labels = .init(allocator), .scopeStack = scopeStack, .switchTags = .init(allocator) };
}

pub fn deinit(self: *Context) void {
    for (self.scopeStack.items) |*scope| {
        scope.identifiers.deinit();
    }

    var it = self.labels.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.labels.deinit();

    self.scopeStack.deinit(self.allocator);
    self.switchTags.deinit();
}

pub fn getScope(self: Context) *Scope {
    const scope = self.scopeStack.last() orelse emptyScope();
    return scope;
}

pub fn getBreakTag(self: Context) ?[]const u8 {
    var i = self.scopeStack.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.scopeStack.items[i].type) {
            .Switch, .Loop => return self.scopeStack.items[i].tag,
            else => {},
        }
    }
    return null;
}

pub fn getContinueTag(self: Context) ?[]const u8 {
    var i = self.scopeStack.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.scopeStack.items[i].type) {
            .Loop => return self.scopeStack.items[i].tag,
            else => {},
        }
    }
    return null;
}

pub fn getSwitchTag(self: Context) ?[]const u8 {
    var i = self.scopeStack.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.scopeStack.items[i].type) {
            .Switch => return self.scopeStack.items[i].tag,
            else => {},
        }
    }
    return null;
}

pub fn pushScope(self: *Context, scopeType: ScopeType, tag: []const u8) void {
    const identifiers = self.getScope().identifiers.clone() catch allocError();
    var it = identifiers.valueIterator();
    while (it.next()) |entry| {
        entry.fromCurrentScope = false;
    }

    self.scopeStack.append(self.allocator, .{
        .type = scopeType,
        .identifiers = identifiers,
        .tag = tag,
    }) catch allocError();
}

pub fn popScope(self: *Context) void {
    var scope = self.scopeStack.pop() orelse emptyScope();
    scope.identifiers.deinit();
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}

fn emptyScope() noreturn {
    std.log.err("No current scope found", .{});
    std.process.exit(1);
}
