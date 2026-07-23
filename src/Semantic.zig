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

var sCounter: usize = 0;

variableMap: VariableMap,

pub fn resolve(allocator: Allocator, ast: *Parser.AST) void {
    var variableMap: VariableMap = .init(allocator);
    defer {
        var it = variableMap.valueIterator();
        while (it.next()) |value| {
            allocator.free(value.*);
        }
        variableMap.deinit();
    }

    const bodyLen = ast.function.body.items.len;
    for (0..bodyLen) |i| {
        var block = ast.function.body.items[i];
        switch (block) {
            .Declaration => |*declaration| resolveDeclaration(allocator, declaration, &variableMap),
            .Statement => |*statement| resolveStatement(allocator, statement, &variableMap),
        }
    }
}

fn resolveDeclaration(allocator: Allocator, declaration: *Declaration, variableMap: *VariableMap) void {
    const name = declaration.name;
    if (variableMap.contains(name)) {
        fatal("Redeclaration of '{s}'", .{name});
    }
    const uniqueName = generateUnique(allocator, name);
    variableMap.put(name, uniqueName) catch @panic("Out of memory");
    if (declaration.initialize) |*expr| {
        resolveExpression(allocator, expr, variableMap);
    }
}

fn resolveStatement(allocator: Allocator, statement: *Statement, variableMap: *VariableMap) void {
    switch (statement.*) {
        .Return => |*ret| resolveExpression(allocator, &ret.expr, variableMap),
        .Expression => |*expr| resolveExpression(allocator, expr, variableMap),
        .Null => {},
    }
}

fn resolveExpression(allocator: Allocator, expr: *Expression, variableMap: *VariableMap) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.left.* != .Factor or assign.left.*.Factor != .Var) fatal("Expression is not an assignable lvalue", .{});

            resolveExpression(allocator, assign.left, variableMap);
            resolveExpression(allocator, assign.right, variableMap);
        },
        .Binary => |*binary| {
            resolveExpression(allocator, binary.left, variableMap);
            resolveExpression(allocator, binary.right, variableMap);
        },
        .Factor => |*factor| resolveFactor(allocator, factor, variableMap),
    }
}

fn resolveFactor(allocator: Allocator, factor: *Factor, variableMap: *VariableMap) void {
    switch (factor.*) {
        .Var => {
            if (variableMap.get(factor.Var)) |unique| {
                factor.Var = unique;
            } else fatal("Use of undeclared identifier '{s}'", .{factor.Var});
        },
        .Unary => |unary| resolveFactor(allocator, unary.operand, variableMap),
        else => {},
    }
}

fn generateUnique(allocator: Allocator, name: []const u8) []u8 {
    defer sCounter += 1;
    return std.fmt.allocPrint(allocator, "{s}.{d}", .{ name, sCounter }) catch @panic("Out of memory");
}
