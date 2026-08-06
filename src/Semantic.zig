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
errors: std.ArrayList(SemanticError) = .empty,

const SemanticError = struct {
    lineIndex: usize,
    type: enum {
        Redeclaration,
        UndeclaredIdentifier,
        NotAssignable,
    },
    name: ?[]const u8 = null,
};

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

fn resolveDeclaration(self: *Semantic, decl: *Declaration) void {
    const name = decl.name;
    if (self.variableMap.contains(name)) {
        self.errors.append(self.allocator, .{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
    }
    const uniqueName = self.generateUnique(name);
    self.variableMap.put(name, uniqueName) catch allocError();

    if (decl.initialize) |*initExpr| {
        self.resolveExpression(initExpr);
    }
}

fn resolveStatement(self: *Semantic, statement: *Statement) void {
    switch (statement.*) {
        .Return => |*ret| self.resolveExpression(&ret.expr),
        .Expression => |*expr| self.resolveExpression(expr),
        .Null => {},
    }
}

fn resolveExpression(self: *Semantic, expr: *Expression) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.lhs.* != .Var) {
                self.errors.append(self.allocator, .{ .lineIndex = assign.lineIndex, .type = .NotAssignable }) catch allocError();
            }

            self.resolveExpression(assign.lhs);
            self.resolveExpression(assign.rhs);
        },
        .Binary => |*binary| {
            self.resolveExpression(binary.left);
            self.resolveExpression(binary.right);
        },
        .Var => |*v| {
            if (self.variableMap.get(v.*.name)) |unique| {
                v.*.name = unique;
            } else {
                self.errors.append(self.allocator, .{ .lineIndex = v.*.lineIndex, .type = .UndeclaredIdentifier, .name = v.*.name }) catch allocError();
            }
        },
        .Unary => |unary| {
            switch (unary.operator) {
                .Inc, .Dec => {
                    if (unary.operand.* != .Var) {
                        self.errors.append(self.allocator, .{ .lineIndex = unary.lineIndex, .type = .NotAssignable }) catch allocError();
                    }
                },
                else => {},
            }
            self.resolveExpression(unary.operand);
        },
        .Constant => {},
    }
}

fn generateUnique(self: *Semantic, name: []const u8) []u8 {
    defer self.sCounter += 1;
    return std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ name, self.sCounter }) catch allocError();
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
