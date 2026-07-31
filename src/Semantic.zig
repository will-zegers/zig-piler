const std = @import("std");
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");
const BlockItem = Parser.BlockItem;
const Factor = Parser.Factor;
const Declaration = Parser.Declaration;
const Statement = Parser.Statement;
const Return = Parser.Return;
const Expression = Parser.Expression;
const Assignment = Parser.Assignment;

const Semantic = @This();

const VariableMap = std.StringHashMap([]const u8);
const AST = Parser.AST;

sCounter: usize = 0,
allocator: Allocator,
variableMap: VariableMap,

pub fn init(allocator: Allocator) Semantic {
    return .{ .allocator = allocator, .variableMap = .init(allocator) };
}

pub fn deinit(self: *Semantic) void {
    var it = self.variableMap.valueIterator();
    while (it.next()) |value| {
        self.allocator.free(value.*);
    }
    self.variableMap.deinit();
}

pub fn resolve(self: *Semantic, ast: *AST) void {
    const body = ast.function.body.items;
    for (body) |*block| {
        switch (block.*) {
            .Declaration => |*declaration| self.resolveDeclaration(declaration),
            .Statement => |*statement| self.resolveStatement(statement),
        }
    }
}

fn resolveDeclaration(self: *Semantic, declaration: *Declaration) void {
    const name = declaration.name;
    if (self.variableMap.contains(name)) {
        fatal("Redeclaration of '{s}'", .{name});
    }
    const uniqueName = self.generateUnique(name);
    self.variableMap.put(name, uniqueName) catch @panic("Out of memory");
    self.resolveExpression(&declaration.initialize);
}

fn resolveStatement(self: Semantic, statement: *Statement) void {
    switch (statement.*) {
        .Return => |*ret| self.resolveExpression(&ret.expr),
        .Expression => |*expr| self.resolveExpression(expr),
        .Null => {},
    }
}

fn resolveExpression(self: Semantic, expr: *Expression) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.left.* != .Factor or assign.left.*.Factor != .Var) {
                fatal("Expression is not an assignable lvalue", .{});
            }

            self.resolveExpression(assign.left);
            self.resolveExpression(assign.right);
        },
        .Binary => |*binary| {
            self.resolveExpression(binary.left);
            self.resolveExpression(binary.right);
        },
        .Factor => |*factor| self.resolveFactor(factor),
    }
}

fn resolveFactor(self: Semantic, factor: *Factor) void {
    switch (factor.*) {
        .Var => {
            if (self.variableMap.get(factor.Var)) |unique| {
                factor.Var = unique;
            } else fatal("Use of undeclared identifier '{s}'", .{factor.Var});
        },
        .Unary => |unary| self.resolveFactor(unary.operand),
        else => {},
    }
}

fn generateUnique(self: *Semantic, name: []const u8) []u8 {
    defer self.sCounter += 1;
    return std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ name, self.sCounter }) catch @panic("Out of memory");
}
