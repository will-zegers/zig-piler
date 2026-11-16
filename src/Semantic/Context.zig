// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log;
const process = std.process;

const Parser = @import("../Parser.zig");
const Label = Parser.Label;
const Goto = Parser.Goto;

const Error = @import("Error.zig");
const Switch = @import("../Parser.zig").Switch;

const Context = @This();

const Entry = struct {
    unique: []const u8,
    fromCurrentScope: bool = true,
    hasLinkage: bool = false,
};

const IdentifierMap = std.StringHashMap(Entry);

pub const FILE_SCOPE = "_global";
const ScopeType = enum {
    File,
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
err: *Error.Reporter,
labels: IdentifierMap,
scopeStack: ArrayList(Scope),
switches: ArrayList(*Switch) = .empty,
function: ?[]const u8 = null, // TODO: maybe move to scope
counter: usize = 0,

pub fn init(allocator: Allocator, errorReporter: *Error.Reporter) Allocator.Error!Context {
    var scopeStack: ArrayList(Scope) = .empty;
    try scopeStack.append(allocator, .{
        .type = .File,
        .identifiers = .init(allocator),
        .tag = FILE_SCOPE,
    });

    return .{
        .allocator = allocator,
        .err = errorReporter,
        .labels = .init(allocator),
        .scopeStack = scopeStack,
    };
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
    self.switches.deinit(self.allocator);
}

pub fn getScope(self: Context) *Scope {
    const scope = self.scopeStack.lastPtr() orelse emptyScope();
    return scope;
}

pub fn addNewLabel(self: *Context, label: *Label, unique: []const u8) !void {
    const name = label.name;
    if (self.function == null) {
        self.err.report(.OrphanLabel, label.lineIndex, name);
        return;
    }

    const key = try self.allocator.print("{s}.{s}", .{ self.function.?, name });
    if (self.labels.contains(key)) {
        self.allocator.free(key);
        self.err.report(.Redeclaration, label.lineIndex, name);
        return;
    }

    label.tag = unique;
    try self.labels.put(key, .{ .unique = unique });
}

pub fn getGotoLabel(self: Context, goto: *Goto) Allocator.Error!?[]const u8 {
    if (self.function == null) {
        self.err.report(.OrphanGoto, goto.lineIndex, goto.target);
        return null;
    }

    const key = try self.allocator.print("{s}.{s}", .{ self.function.?, goto.target });
    defer self.allocator.free(key);

    if (self.labels.get(key)) |entry| {
        return entry.unique;
    } else {
        self.err.report(.Redeclaration, goto.lineIndex, goto.target);
        return null;
    }
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

pub fn pushScope(self: *Context, scopeType: ScopeType, tag: []const u8) Allocator.Error!void {
    const identifiers = try self.getScope().identifiers.clone();
    var it = identifiers.valueIterator();
    while (it.next()) |entry| {
        entry.fromCurrentScope = false;
    }

    try self.scopeStack.append(self.allocator, .{
        .type = scopeType,
        .identifiers = identifiers,
        .tag = tag,
    });
}

pub fn popScope(self: *Context) void {
    var scope = self.scopeStack.pop() orelse emptyScope();
    scope.identifiers.deinit();
}

fn emptyScope() noreturn {
    std.log.err("No current scope found", .{});
    std.process.exit(1);
}
