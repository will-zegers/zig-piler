// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const fatal = std.process.fatal;

const Parser = @import("Parser.zig");
const Declaration = Parser.Declaration;
const Statement = Parser.Statement;
const Expression = Parser.Expression;
const Switch = Parser.Switch;

const Semantic = @This();

const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;

const AST = Parser.AST;

allocator: Allocator,
switches: std.StringHashMap(*Switch),
uniqueIds: std.ArrayList([]const u8) = .empty,
errors: std.ArrayList(SemanticError) = .empty,

const SemanticError = struct {
    lineIndex: usize,
    type: enum {
        Break,
        CaseOutside,
        CaseDuplicate,
        Continue,
        Redeclaration,
        UndeclaredIdentifier,
        NotAssignable,
    },
    name: ?[]const u8 = null,
};

pub fn init(allocator: Allocator) Semantic {
    return .{ .allocator = allocator, .switches = .init(allocator) };
}

pub fn deinit(self: *Semantic) void {
    self.switches.deinit();

    self.errors.deinit(self.allocator);
}

pub fn resolve(self: *Semantic, ast: *AST) [][]const u8 {
    var context: Context = .init(self.allocator);
    defer context.deinit();

    resolveFirstPass(self, ast, &context);
    resolveSecondPass(self, ast, &context);

    return self.uniqueIds.toOwnedSlice(self.allocator) catch allocError();
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

/// On first-pass:
///   1) ensure that variables are declared, in scope, and resolve them to unique names
///   2) collect all declared labels into a map structure for resolution in pass 2 (since
///      labels may be used before they're declared, i.e. gotos)
///   3) collect all individual cases into their respective switch statements for use in TAC gen
fn resolveStatement1P(self: *Semantic, statement: *Statement, context: *Context) void {
    switch (statement.*) {
        .Compound => |*compound| {
            const newTag = self.generateUnique(context.function, "while");

            context.pushScope(.Block, newTag);
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
            self.resolveStatement1P(ifStmt.thenStmt, context);
            if (ifStmt.elseStmt) |*elseStmt| {
                self.resolveStatement1P(elseStmt.*, context);
            }
        },
        .Label => |*lbl| {
            const tag = statement.Label.tag;
            if (context.labels.get(tag)) |entry| {
                if (entry.insideScope) {
                    self.errors.append(self.allocator, .{ .lineIndex = lbl.lineIndex, .type = .Redeclaration, .name = tag }) catch allocError();
                    return;
                }
            }
            const unique = self.generateUnique(context.function, tag);
            context.labels.put(tag, .{ .unique = unique }) catch allocError();

            lbl.*.tag = unique;

            self.resolveStatement1P(lbl.body, context);
        },
        .Break => |*brk| if (context.getBreakTag()) |tag| {
            brk.tag = tag;
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = brk.lineIndex, .type = .Break }) catch allocError();
        },
        .Continue => |*cont| if (context.getContinueTag()) |tag| {
            if (std.mem.indexOf(u8, tag, "switch")) |_| {
                self.errors.append(self.allocator, .{ .lineIndex = cont.lineIndex, .type = .Continue }) catch allocError();
            } else cont.tag = tag;
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = cont.lineIndex, .type = .Continue }) catch allocError();
        },
        .DoWhile => |*doWhl| {
            const newTag = self.generateUnique(context.function, "doWhile");
            doWhl.tag = newTag;

            context.pushScope(.Loop, newTag);

            self.resolveStatement1P(doWhl.body, context);
            self.resolveExpression(&doWhl.cond, context);
        },
        .While => |*whl| {
            self.resolveExpression(&whl.cond, context);

            const newTag = self.generateUnique(context.function, "while");
            whl.tag = newTag;

            context.pushScope(.Loop, newTag);
            self.resolveStatement1P(whl.body, context);
        },
        .For => |*f| {
            const newTag = self.generateUnique(context.function, "for");
            f.tag = newTag;

            context.pushScope(.Loop, newTag);
            defer context.popScope();

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
        .Switch => |*swtch| {
            self.resolveExpression(&swtch.cond, context);

            const newTag = self.generateUnique(context.function, "switch");
            swtch.tag = newTag;

            context.pushScope(.Switch, newTag);
            defer context.popScope();

            self.switches.put(swtch.tag, swtch) catch allocError();

            self.resolveStatement1P(swtch.body, context);
        },
        .Case => |*case| if (context.getSwitchTag()) |switchTag| {
            const cond = if (case.cond) |cond| cond.Constant else "default";
            const newTag = self.allocator.print("{s}.{s}", .{switchTag, cond}) catch allocError();
            self.uniqueIds.append(self.allocator, newTag) catch allocError();
            case.tag = newTag;

            const parentSwitch = self.switches.get(switchTag) orelse unreachable;
            parentSwitch.*.addCase(case) catch {
                self.errors.append(self.allocator, .{
                    .lineIndex = case.lineIndex,
                    .type = .CaseDuplicate,
                }) catch allocError();
            };

            if (case.body) |body| self.resolveStatement1P(body, context);
        } else {
            self.errors.append(self.allocator, .{ .lineIndex = case.lineIndex, .type = .CaseOutside }) catch allocError();
        },
    }
}

/// On second pass: resolve all labels to their unique names, using the map from the 1st pass
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
            self.resolveStatement2P(ifStmt.thenStmt, context);
            if (ifStmt.elseStmt) |*elseStmt| self.resolveStatement2P(elseStmt.*, context);
        },
        .Switch => |*swtch| self.resolveStatement2P(swtch.body, context),
        .Case => |*case| if (case.body) |body| self.resolveStatement2P(body, context),
        .Label => |*label| self.resolveStatement2P(label.body, context),
        .DoWhile, => |*loop| self.resolveStatement2P(loop.body, context),
        .For, => |*loop| self.resolveStatement2P(loop.body, context),
        .While => |*loop| self.resolveStatement2P(loop.body, context),
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
            self.resolveExpression(ternary.thenStmt, context);
            self.resolveExpression(ternary.elseStmt, context);
        },
    }
}

fn generateUnique(self: *Semantic, function: []const u8, name: []const u8) []u8 {
    const unique = self.allocator.print("{s}.{s}.{d}", .{ function, name, self.uniqueIds.items.len }) catch allocError();
    self.uniqueIds.append(self.allocator, unique) catch allocError();
    return unique;
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
