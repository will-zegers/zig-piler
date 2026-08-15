const std = @import("std");
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");
const Declaration = Parser.Declaration;
const Statement = Parser.Statement;
const Expression = Parser.Expression;

const Semantic = @This();

const IdentifierMap = std.StringHashMap(Entry);
const AST = Parser.AST;

const Entry = struct {
    unique: []const u8,
    insideScope: bool = true,
};

const Context = struct {
    allocator: Allocator,
    labels: IdentifierMap,
    variables: IdentifierMap,
    loopTag: ?[]const u8 = null,
    function: []const u8 = "main",

    pub fn init(allocator: Allocator) Context {
        return .{
            .allocator = allocator,
            .labels = .init(allocator),
            .variables = .init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.variables.deinit();
        self.labels.deinit();
    }

    pub fn clone(self: Context) Context {
        return .{
            .allocator = self.allocator,
            .variables = newScope(self.variables),
            .labels = self.labels,
            .loopTag = self.loopTag,
        };
    }

    fn newScope(map: IdentifierMap) IdentifierMap {
        var newMap = map.clone() catch allocError();
        var it = newMap.valueIterator();
        while (it.next()) |*entry| {
            entry.*.insideScope = false;
        }

        return newMap;
    }
};

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
    if (context.variables.get(name)) |entry| {
        if (entry.insideScope) {
            self.errors.append(self.allocator, .{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = name }) catch allocError();
            return;
        }
    }
    const unique = self.generateUnique(name);
    context.variables.put(name, .{ .unique = unique }) catch allocError();

    if (decl.init) |*initExpr| {
        self.resolveExpression(initExpr, context);
    }
}

fn resolveStatement1P(self: *Semantic, statement: *Statement, context: *Context) void {
    switch (statement.*) {
        .Compound => |*compound| {
            var scopedContext = context.clone();
            defer scopedContext.deinit();

            for (compound.items) |*item| {
                switch (item.*) {
                    .Statement => |*stmt| self.resolveStatement1P(stmt, &scopedContext),
                    .Declaration => |*decl| self.resolveDeclaration(decl, &scopedContext),
                }
            }
        },
        .Return => |*ret| self.resolveExpression(&ret.expr, context),
        .Expression => |*expr| self.resolveExpression(expr, context),
        .If => |*if_| {
            self.resolveExpression(&if_.condition, context);
            self.resolveStatement1P(if_.then, context);
            if (if_.else_) |*else_| {
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
            const unique = self.generateUnique(name);
            context.labels.put(name, .{ .unique = unique }) catch allocError();

            lbl.*.name = unique;

            self.resolveStatement1P(lbl.statement, context);
        },
        .Break => |*brk| if (context.loopTag) |tag| {
            brk.tag = tag;
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = brk.lineIndex, .type = .Break }) catch allocError();
        },
        .Continue => |*cont| if (context.loopTag) |tag| {
            cont.tag = tag;
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = cont.lineIndex, .type = .Continue }) catch allocError();
        },
        .DoWhile => |*doWhl| {
            // Save the current scope tag, and restore it on return
            const currentLabel = context.loopTag;
            defer context.loopTag = currentLabel;

            const newLabel = self.generateUnique("doWhile");
            doWhl.tag = newLabel;
            context.loopTag = newLabel;

            self.resolveStatement1P(doWhl.body, context);
            self.resolveExpression(&doWhl.cond, context);
        },
        .While => |*whl| {
            self.resolveExpression(&whl.cond, context);

            // Save the current scope tag, and restore it on return
            const currentLabel = context.loopTag;
            defer context.loopTag = currentLabel;

            const newLabel = self.generateUnique("while");
            whl.tag = newLabel;
            context.loopTag = newLabel;

            self.resolveStatement1P(whl.body, context);
        },
        .For => |*f| {
            var scopedContext = context.clone();
            defer scopedContext.deinit();

            const newLabel = self.generateUnique("for");
            f.tag = newLabel;
            scopedContext.loopTag = newLabel;

            switch (f.init) {
                .Declaration => self.resolveDeclaration(&f.init.Declaration, &scopedContext),
                .Expression => if (f.init.Expression) |*expr| {
                    self.resolveExpression(expr, &scopedContext);
                },
            }
            if (f.cond) |*cond| self.resolveExpression(cond, &scopedContext);
            if (f.post) |*post| self.resolveExpression(post, &scopedContext);

            self.resolveStatement1P(f.body, &scopedContext);
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
        .If => |*if_| {
            self.resolveStatement2P(if_.then, context);
            if (if_.else_) |*else_| {
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
            if (context.variables.get(v.*.name)) |entry| {
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

fn generateUnique(self: *Semantic, name: []const u8) []u8 {
    const unique = std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ name, self.uniqueIds.items.len }) catch allocError();
    self.uniqueIds.append(self.allocator, unique) catch allocError();
    return unique;
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
