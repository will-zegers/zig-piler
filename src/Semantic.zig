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

const IdentifierMap = std.StringHashMap([]const u8);
const AST = Parser.AST;

sCounter: usize = 0,
allocator: Allocator,
variableMap: IdentifierMap,
labelMap: IdentifierMap,
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
    var it = self.variableMap.valueIterator();
    while (it.next()) |value| {
        self.allocator.free(value.*);
    }

    it = self.labelMap.valueIterator();
    while (it.next()) |value| {
        self.allocator.free(value.*);
    }

    self.variableMap.deinit();
    self.labelMap.deinit();
}

pub fn resolve(self: *Semantic, ast: *AST) void {
    resolveFirstPass(self, ast);
    resolveSecondPass(self, ast);
}

fn resolveFirstPass(self: *Semantic, ast: *AST) void {
    const body = ast.function.body;
    for (body) |*block| {
        switch (block.*) {
            .Statement => |*statement| self.resolveStatementFP(statement),
            .Declaration => |*declaration| self.resolveDeclarations(declaration),
        }
    }
}

fn resolveSecondPass(self: *Semantic, ast: *AST) void {
    const body = ast.function.body;
    for (body) |*block| {
        switch (block.*) {
            .Statement => |*statement| self.resolveStatementSP(statement),
            .Declaration => {},
        }
    }
}

fn resolveDeclarations(self: *Semantic, decl: *Declaration) void {
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

fn resolveStatementFP(self: *Semantic, statement: *Statement) void {
    switch (statement.*) {
        .Return => |*ret| self.resolveExpression(&ret.expr),
        .Expression => |*expr| self.resolveExpression(expr),
        .If => |*if_| {
            self.resolveExpression(&if_.condition);
            self.resolveStatementFP(if_.then);
            if (if_.else_) |*else_| {
                self.resolveStatementFP(else_.*);
            }
        },
        .Label => |*lbl| {
            const name = statement.Label.name;
            if (self.labelMap.contains(name)) {
                self.errors.append(self.allocator, .{ .lineIndex = lbl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
            }
            const uniqueName = self.generateUnique(name);
            self.labelMap.put(name, uniqueName) catch allocError();

            lbl.*.name = uniqueName;

            self.resolveStatementFP(lbl.statement);
        },
        .Goto, .Null => {},
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
        .Ternary => |*ternary| {
            self.resolveExpression(ternary.condition);
            self.resolveExpression(ternary.then);
            self.resolveExpression(ternary.else_);
        },
    }
}

fn resolveStatementSP(self: *Semantic, statement: *Statement) void {
    switch (statement.*) {
        .Goto => |*goto| {
            if (self.labelMap.get(goto.*.label)) |unique| {
                goto.*.label = unique;
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
    defer self.sCounter += 1;
    return std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ name, self.sCounter }) catch allocError();
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
