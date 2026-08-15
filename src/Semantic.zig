const std = @import("std");
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");
const Declaration = Parser.Declaration;
const Statement = Parser.Statement;
const Expression = Parser.Expression;

const Semantic = @This();

const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;

const AST = Parser.AST;

allocator: Allocator,
uniqueIds: std.ArrayList([]const u8) = .empty,
errors: std.ArrayList(SemanticError) = .empty,

const SemanticError = struct {
    lineIndex: usize,
    type: enum {
        Break,
        Continue,
        Redeclaration,
        UndeclaredIdentifier,
        NotAssignable,
    },
    name: ?[]const u8 = null,
};

pub fn init(allocator: Allocator) Semantic {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Semantic) void {
    for (self.uniqueIds.items) |item| {
        self.allocator.free(item);
    }

    self.uniqueIds.deinit(self.allocator);
    self.errors.deinit(self.allocator);
}

pub fn resolve(self: *Semantic, ast: *AST) void {
    var context: Context = .init(self.allocator);
    defer context.deinit();

    resolveFirstPass(self, ast, &context);
    resolveSecondPass(self, ast, &context);
}

fn resolveFirstPass(self: *Semantic, ast: *AST, context: *Context) void {
    const body = ast.function.body.items;
    for (body) |*block| {
        switch (block.*) {
            .Statement => |*statement| self.resolveStatement1P(statement, context),
            .Declaration => |*declaration| self.resolveDeclaration(declaration, context),
        }
    }
}

fn resolveSecondPass(self: *Semantic, ast: *AST, context: *Context) void {
    const body = ast.function.body.items;
    for (body) |*block| {
        switch (block.*) {
            .Statement => |*statement| self.resolveStatement2P(statement, context),
            .Declaration => {},
        }
    }
}

fn resolveDeclaration(self: *Semantic, decl: *Declaration, context: *Context) void {
    const name = decl.name;
    if (context.getScope().variables.get(name)) |entry| {
        if (entry.insideScope) {
            self.errors.append(self.allocator, .{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
            return;
        }
    }
    const unique = self.generateUnique(context.function, name);
    context.*.getScopeMut().variables.put(name, .{ .unique = unique }) catch allocError();

    if (decl.init) |*initExpr| {
        self.resolveExpression(initExpr, context);
    }
}

fn resolveStatement1P(self: *Semantic, statement: *Statement, context: *Context) void {
    switch (statement.*) {
        .Compound => |*compound| {
            context.pushScope(context.*.getScope().loopTag);
            defer context.popScope();

            for (compound.items) |*item| {
                switch (item.*) {
                    .Statement => |*stmt| self.resolveStatement1P(stmt, context),
                    .Declaration => |*decl| self.resolveDeclaration(decl, context),
                }
            }
        },
        .Return => |*ret| self.resolveExpression(&ret.expr, context),
        .Expression => |*expr| self.resolveExpression(expr, context),
        .If => |*ifStmt| {
            self.resolveExpression(&ifStmt.condition, context);
            self.resolveStatement1P(ifStmt.then, context);
            if (ifStmt.else_) |*else_| {
                self.resolveStatement1P(else_.*, context);
            }
        },
        .Label => |*lbl| {
            const name = statement.Label.name;
            if (context.labels.get(name)) |entry| {
                if (entry.insideScope) {
                    self.errors.append(self.allocator, .{ .lineIndex = lbl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
                    return;
                }
            }
            const unique = self.generateUnique(context.function, name);
            context.labels.put(name, .{ .unique = unique }) catch allocError();

            lbl.*.name = unique;

            self.resolveStatement1P(lbl.statement, context);
        },
        .Break => |*brk| if (context.getScope().loopTag) |tag| {
            brk.tag = tag;
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = brk.lineIndex, .type = .Break }) catch allocError();
        },
        .Continue => |*cont| if (context.getScope().loopTag) |tag| {
            cont.tag = tag;
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = cont.lineIndex, .type = .Continue }) catch allocError();
        },
        .DoWhile => |*doWhl| {
            const newTag = self.generateUnique(context.function, "doWhile");
            doWhl.tag = newTag;

            context.pushScope(newTag);

            self.resolveStatement1P(doWhl.body, context);
            self.resolveExpression(&doWhl.cond, context);
        },
        .While => |*whl| {
            self.resolveExpression(&whl.cond, context);

            const newTag = self.generateUnique(context.function, "while");
            whl.tag = newTag;

            context.pushScope(newTag);
            self.resolveStatement1P(whl.body, context);
        },
        .For => |*f| {
            const newTag = self.generateUnique(context.function, "for");
            f.tag = newTag;

            context.pushScope(newTag);

            switch (f.init) {
                .Declaration => self.resolveDeclaration(&f.init.Declaration, context),
                .Expression => if (f.init.Expression) |*expr| {
                    self.resolveExpression(expr, context);
                },
            }
            if (f.cond) |*cond| self.resolveExpression(cond, context);
            if (f.post) |*post| self.resolveExpression(post, context);

            self.resolveStatement1P(f.body, context);
        },
        .Goto, .Null => {}, // gotos are resolved on the second pass
    }
}

fn resolveStatement2P(self: *Semantic, statement: *Statement, context: *Context) void {
    switch (statement.*) {
        .Compound => |*compound| {
            for (compound.items) |*item| {
                switch (item.*) {
                    .Statement => |*stmt| self.resolveStatement2P(stmt, context),
                    .Declaration => {},
                }
            }
        },
        .Goto => |*goto| {
            if (context.labels.get(goto.*.target)) |entry| {
                goto.*.target = entry.unique;
            } else {
                self.errors.append(self.allocator, .{ .lineIndex = goto.*.lineIndex, .type = .UndeclaredIdentifier, .name = goto.*.target }) catch allocError();
            }
        },
        .If => |*ifStmt| {
            self.resolveStatement2P(ifStmt.then, context);
            if (ifStmt.else_) |*else_| {
                self.resolveStatement2P(else_.*, context);
            }
        },
        .Label => |*lbl| self.resolveStatement2P(lbl.statement, context),
        else => {},
    }
}

fn resolveExpression(self: *Semantic, expr: *Expression, context: *Context) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.lhs.* != .Var) {
                self.errors.append(self.allocator, .{ .lineIndex = assign.lineIndex, .type = .NotAssignable }) catch allocError();
            }

            self.resolveExpression(assign.lhs, context);
            self.resolveExpression(assign.rhs, context);
        },
        .Binary => |*binary| {
            self.resolveExpression(binary.left, context);
            self.resolveExpression(binary.right, context);
        },
        .Var => |*v| {
            if (context.getScope().variables.get(v.*.name)) |entry| {
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
            self.resolveExpression(unary.operand, context);
        },
        .Constant => {},
        .Ternary => |*ternary| {
            self.resolveExpression(ternary.condition, context);
            self.resolveExpression(ternary.then, context);
            self.resolveExpression(ternary.else_, context);
        },
    }
}

fn generateUnique(self: *Semantic, function: []const u8, name: []const u8) []u8 {
    const unique = std.fmt.allocPrint(self.allocator, "{s}.{s}.{d}", .{ function, name, self.uniqueIds.items.len }) catch allocError();
    self.uniqueIds.append(self.allocator, unique) catch allocError();
    return unique;
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
