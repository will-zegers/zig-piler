const std = @import("std");
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");
const Declaration = Parser.Declaration;
const Statement = Parser.Statement;
const Expression = Parser.Expression;

const Semantic = @This();

const Entry = struct {
    unique: []const u8,
    insideScope: bool = true,
};

const IdentifierMap = std.StringHashMap(Entry);
const AST = Parser.AST;

allocator: Allocator,
variableMap: IdentifierMap,
labelMap: IdentifierMap,
uniqueIds: std.ArrayList([]const u8) = .empty,
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
    return .{ .allocator = allocator, .variableMap = .init(allocator), .labelMap = .init(allocator) };
}

pub fn deinit(self: *Semantic) void {
    for (self.uniqueIds.items) |item| {
        self.allocator.free(item);
    }

    self.variableMap.deinit();
    self.labelMap.deinit();
    self.uniqueIds.deinit(self.allocator);
}

pub fn resolve(self: *Semantic, ast: *AST) void {
    resolveFirstPass(self, ast);
    resolveSecondPass(self, ast);
}

fn resolveFirstPass(self: *Semantic, ast: *AST) void {
    const body = ast.function.body.items;
    for (body) |*block| {
        switch (block.*) {
            .Statement => |*statement| self.resolveStatementFP(statement, self.variableMap),
            .Declaration => |*declaration| self.resolveDeclaration(declaration, &self.variableMap),
        }
    }
}

fn resolveSecondPass(self: *Semantic, ast: *AST) void {
    const body = ast.function.body.items;
    for (body) |*block| {
        switch (block.*) {
            .Statement => |*statement| self.resolveStatementSP(statement),
            .Declaration => {},
        }
    }
}

fn resolveDeclaration(self: *Semantic, decl: *Declaration, variableMap: *IdentifierMap) void {
    const name = decl.name;
    if (variableMap.get(name)) |entry| {
        if (entry.insideScope) {
            self.errors.append(self.allocator, .{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
            return;
        }
    }
    const unique = self.generateUnique(name);
    variableMap.put(name, .{ .unique = unique }) catch allocError();

    if (decl.init) |*initExpr| {
        self.resolveExpression(initExpr, variableMap.*);
    }
}

fn resolveStatementFP(self: *Semantic, statement: *Statement, variableMap: IdentifierMap) void {
    switch (statement.*) {
        .Compound => |*compound| {
            var mapClone = newScope(variableMap);
            defer mapClone.deinit();

            for (compound.items) |*item| {
                switch (item.*) {
                    .Statement => |*stmt| self.resolveStatementFP(stmt, mapClone),
                    .Declaration => |*decl| self.resolveDeclaration(decl, &mapClone),
                }
            }
        },
        .Return => |*ret| self.resolveExpression(&ret.expr, variableMap),
        .Expression => |*expr| self.resolveExpression(expr, variableMap),
        .If => |*if_| {
            self.resolveExpression(&if_.condition, variableMap);
            self.resolveStatementFP(if_.then, variableMap);
            if (if_.else_) |*else_| {
                self.resolveStatementFP(else_.*, variableMap);
            }
        },
        .Label => |*lbl| {
            const name = statement.Label.name;
            if (self.labelMap.get(name)) |entry| {
                if (entry.insideScope) {
                    self.errors.append(self.allocator, .{ .lineIndex = lbl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
                    return;
                }
            }
            const unique = self.generateUnique(name);
            self.labelMap.put(name, .{ .unique = unique }) catch allocError();

            lbl.*.name = unique;

            self.resolveStatementFP(lbl.statement, variableMap);
        },
        .Goto, .Null => {},
        else => {}, // TODO: Break, Continue, DoWhile, For, While
    }
}

fn resolveExpression(self: *Semantic, expr: *Expression, variableMap: IdentifierMap) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.lhs.* != .Var) {
                self.errors.append(self.allocator, .{ .lineIndex = assign.lineIndex, .type = .NotAssignable }) catch allocError();
            }

            self.resolveExpression(assign.lhs, variableMap);
            self.resolveExpression(assign.rhs, variableMap);
        },
        .Binary => |*binary| {
            self.resolveExpression(binary.left, variableMap);
            self.resolveExpression(binary.right, variableMap);
        },
        .Var => |*v| {
            if (variableMap.get(v.*.name)) |entry| {
                v.*.name = entry.unique;
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
            self.resolveExpression(unary.operand, variableMap);
        },
        .Constant => {},
        .Ternary => |*ternary| {
            self.resolveExpression(ternary.condition, variableMap);
            self.resolveExpression(ternary.then, variableMap);
            self.resolveExpression(ternary.else_, variableMap);
        },
    }
}

fn resolveStatementSP(self: *Semantic, statement: *Statement) void {
    switch (statement.*) {
        .Compound => |*compound| {
            for (compound.items) |*item| {
                switch (item.*) {
                    .Statement => |*stmt| self.resolveStatementSP(stmt),
                    .Declaration => {},
                }
            }
        },
        .Goto => |*goto| {
            if (self.labelMap.get(goto.*.label)) |entry| {
                goto.*.label = entry.unique;
            } else {
                self.errors.append(self.allocator, .{ .lineIndex = goto.*.lineIndex, .type = .UndeclaredIdentifier, .name = goto.*.label }) catch allocError();
            }
        },
        .If => |*if_| {
            self.resolveStatementSP(if_.then);
            if (if_.else_) |*else_| {
                self.resolveStatementSP(else_.*);
            }
        },
        .Label => |*lbl| {
            self.resolveStatementSP(lbl.statement);
        },
        else => {},
    }
}

fn generateUnique(self: *Semantic, name: []const u8) []u8 {
    const unique = std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ name, self.uniqueIds.items.len }) catch allocError();
    self.uniqueIds.append(self.allocator, unique) catch allocError();
    return unique;
}

fn newScope(map: IdentifierMap) IdentifierMap {
    var mapClone = map.clone() catch allocError();
    var it = mapClone.valueIterator();
    while (it.next()) |*entry| {
        entry.*.insideScope = false;
    }

    return mapClone;
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
