const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @This();

const Entry = struct {
    unique: []const u8,
    insideScope: bool = true,
};

const IdentifierMap = std.StringHashMap(Entry);

const ScopeType = enum {
    Global,
    Block,
    Loop,
    Switch,
};

const Scope = struct {
    type: ScopeType,
    variables: IdentifierMap,
    tag: []const u8,
};

allocator: Allocator,
labels: IdentifierMap,
function: []const u8 = "main",
stack: std.ArrayList(Scope),

pub fn init(allocator: Allocator) Context {
    var stack: std.ArrayList(Scope) = .empty;
    stack.append(allocator, .{
        .type = .Block,
        .variables = .init(allocator),
        .tag = "main",
    }) catch allocError();

    return .{ .allocator = allocator, .labels = .init(allocator), .stack = stack };
}

pub fn deinit(self: *Context) void {
    defer self.stack.deinit(self.allocator);
    for (self.stack.items) |*scope| {
        scope.variables.deinit();
    }
    self.labels.deinit();
}

pub fn getScope(self: Context) Scope {
    const scope = self.stack.last() orelse emptyScope();
    return scope.*;
}

pub fn getScopeMut(self: Context) *Scope {
    const scope = self.stack.last() orelse emptyScope();
    return scope;
}

pub fn getBreakTag(self: Context) ?[]const u8 {
    var i = self.stack.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.stack.items[i].type) {
            .Switch, .Loop => return self.stack.items[i].tag,
            else => {},
        }
    }
    return null;
}

pub fn getContinueTag(self: Context) ?[]const u8 {
    var i = self.stack.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.stack.items[i].type) {
            .Loop => return self.stack.items[i].tag,
            else => {},
        }
    }
    return null;
}

pub fn getSwitchTag(self: Context) ?[]const u8 {
    var i = self.stack.items.len;
    while (i > 0) {
        i -= 1;
        switch (self.stack.items[i].type) {
            .Switch => return self.stack.items[i].tag,
            else => {},
        }
    }
    return null;
}

pub fn pushScope(self: *Context, scopeType: ScopeType, tag: []const u8) void {
    const variables = self.getScope().variables.clone() catch allocError();
    var it = variables.valueIterator();
    while (it.next()) |*entry| {
        entry.*.insideScope = false;
    }

    self.stack.append(self.allocator, .{
        .type = scopeType,
        .variables = variables,
        .tag = tag,
    }) catch allocError();
}

pub fn popScope(self: *Context) void {
    var scope = self.stack.pop() orelse emptyScope();
    scope.variables.deinit();
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}

fn emptyScope() noreturn {
    std.log.err("No current scope found", .{});
    std.process.exit(1);
}
