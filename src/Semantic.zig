const std = @import("std");
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");
const BlockItem = Parser.BlockItem;
const Declaration = Parser.Declaration;
const Statement = Parser.Statement;
const Return = Parser.Return;
const Expression = Parser.Expression;
const Assignment = Parser.Assignment;

const Semantic = @This();

const VariableMap = std.StringHashMap([]const u8);

var sCounter: usize = 0;

variableMap: VariableMap,

pub fn init(allocator: Allocator, ast: *Parser.AST) void {
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
        const block = ast.function.body.items[i];
        const blockItem: BlockItem = switch (block) {
            .Declaration => |declaration| .{ .Declaration = resolveDeclaration(allocator, declaration, &variableMap) },
            .Statement => |statement| .{ .Statement = resolveStatement(allocator, statement, &variableMap) },
        };
        ast.function.body.append(allocator, blockItem) catch @panic("OOM");
        _ = ast.function.body.swapRemove(i);
    }
}

fn resolveDeclaration(allocator: Allocator, declaration: Declaration, variableMap: *VariableMap) Declaration {
    const name = declaration.name;
    if (variableMap.contains(name)) {
        fatal("Redeclaration of '{s}'", .{name});
    }
    const uniqueName = generateUnique(allocator, name);
    variableMap.put(name, uniqueName) catch @panic("OOM");
    const initialize = if (declaration.initialize) |expr|
        resolveExpression(allocator, expr, variableMap)
    else
        null;

    return .{ .name = uniqueName, .initialize = initialize };
}

fn resolveStatement(allocator: Allocator, statement: Statement, variableMap: *VariableMap) Statement {
    return switch (statement) {
        .Return => |ret| .{ .Return = .{ .allocator = allocator, .expr = resolveExpression(allocator, ret.expr, variableMap) } },
        .Expression => |expr| .{ .Expression = resolveExpression(allocator, expr, variableMap) },
        .Null => Statement.Null,
    };
}

fn resolveExpression(allocator: Allocator, expr: Expression, variableMap: *VariableMap) Expression {
    std.debug.print("{any}\n", .{expr});
    return switch (expr) {
        .Assignment => |assign| ret: {
            defer allocator.destroy(assign.left);
            defer allocator.destroy(assign.right);

            if (assign.left.* != .Factor or assign.left.*.Factor != .Var) fatal("Expression is not an assignable lvalue", .{});
            break :ret .{ .Assignment = .init(
                allocator,
                resolveExpression(allocator, assign.left.*, variableMap),
                resolveExpression(allocator, assign.right.*, variableMap),
            ) };
        },
        .Binary => |binary| ret: {
            defer allocator.destroy(binary.left);
            defer allocator.destroy(binary.right);

            break :ret .{ .Binary = .copy(
                allocator,
                binary.operator,
                resolveExpression(allocator, binary.left.*, variableMap),
                resolveExpression(allocator, binary.right.*, variableMap),
            ) };
        },
        .Factor => |factor| ret: {
            switch (factor) {
                .Var => {
                    if (!variableMap.contains(factor.Var)) {
                        fatal("Use of undeclared identifier '{s}'", .{factor.Var});
                    } else break :ret expr;
                },
                else => break :ret expr,
            }
        },
    };
}

fn generateUnique(allocator: Allocator, name: []const u8) []u8 {
    defer sCounter += 1;
    return std.fmt.allocPrint(allocator, "{s}.{d}", .{ name, sCounter }) catch @panic("Out of memory");
}
