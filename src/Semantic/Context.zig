const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @This();

const Entry = struct {
    unique: []const u8,
    insideScope: bool = true,
};

const IdentifierMap = std.StringHashMap(Entry);

const Scope = struct {
    variables: IdentifierMap,
    loopTag: ?[]const u8 = null,
};

allocator: Allocator,
labels: IdentifierMap,
function: []const u8 = "main",
scopeStack: std.ArrayList(Scope),

pub fn init(allocator: Allocator) Context {
    var scopeStack: std.ArrayList(Scope) = .empty;
    scopeStack.append(allocator, .{
        .variables = .init(allocator),
        .loopTag = null,
    }) catch allocError();

    return .{ .allocator = allocator, .labels = .init(allocator), .scopeStack = scopeStack };
}

pub fn deinit(self: *Context) void {
    defer self.scopeStack.deinit(self.allocator);
    for (self.scopeStack.items) |*scope| {
        scope.variables.deinit();
    }
    self.labels.deinit();
}

pub fn getScope(self: Context) Scope {
    const scope = self.scopeStack.last() orelse emptyScope();
    return scope.*;
}

pub fn getScopeMut(self: Context) *Scope {
    const scope = self.scopeStack.last() orelse emptyScope();
    return scope;
}

pub fn pushScope(self: *Context, loopTag: ?[]const u8) void {
    const variables = self.getScope().variables.clone() catch allocError();
    var it = variables.valueIterator();
    while (it.next()) |*entry| {
        entry.*.insideScope = false;
    }

    self.scopeStack.append(self.allocator, .{
        .variables = variables,
        .loopTag = loopTag,
    }) catch allocError();
}

pub fn popScope(self: *Context) void {
    var scope = self.scopeStack.pop() orelse emptyScope();
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
