// zig fmt: off
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const Parser = @import("Parser.zig");
const Block = Parser.Block;
const Declaration = Parser.Declaration;
const FunDecl = Parser.FunDecl;
const VarDecl = Parser.VarDecl;
const Statement = Parser.Statement;
const Expression = Parser.Expression;
const Switch = Parser.Switch;

const LoopLabeler = @import("Semantic/LoopLabeler.zig");
const TypeChecker = @import("Semantic/TypeChecker.zig");

const Semantic = @This();

const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;

const AST = Parser.AST;

allocator: Allocator,
lines: [][]const u8,
errorFlag: bool = false,

const SemanticError = struct {
    lineIndex: usize,
    type: enum {
        Break,
        CaseDuplicate,
        CaseOutside,
        Continue,
        NestedFunction,
        NotAssignable,
        OrphanLabel,
        Redeclaration,
        UndeclaredIdentifier,
    },
    name: ?[]const u8 = null,
};

pub fn init(allocator: Allocator, lines: [][]const u8) Semantic {
    return .{ .allocator = allocator, .lines = lines };
}

pub fn run(self: *Semantic, ast: *AST) void {
    var context: Context = .init(self.allocator);
    defer context.deinit();

    resolveFirstPass(self, &context, ast);
    if (self.errorFlag) std.process.exit(1);

    LoopLabeler.run(self.allocator, &context, ast);
    TypeChecker.run(self.allocator, ast);

}

fn resolveFirstPass(self: *Semantic, context: *Context, ast: *AST) void {
    for (ast.tree.functions) |*function| self.resolveFunDecl(context, function);
}

fn resolveDeclaration(self: *Semantic, context: *Context, decl: *Declaration) void {
    switch (decl.*) {
        .FunDecl => |*funDecl| self.resolveFunDecl(context, funDecl),
        .VarDecl => |*varDecl|  self.resolveVarDecl(context, varDecl),
    }
}

fn resolveFunDecl(self: *Semantic, context: *Context, decl: *FunDecl) void {
    const scope = context.getScope();
    if (scope.identifiers.get(decl.name)) |entry| {
        if (entry.fromCurrentScope and !entry.hasLinkage) {
            self.reportError(.{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = decl.name });
            return;
        }
    }

    scope.identifiers.put(decl.name, .{
        .unique = decl.name,
        .fromCurrentScope = true,
        .hasLinkage = true
    }) catch allocError();

    context.function = decl.name;
    defer context.function = null;

    context.pushScope(.Function, decl.name);
    defer context.popScope();

    for (decl.params) |*param| {
        self.resolveVarDecl(context, param);
    }

    if (decl.body) |*body| {
        if (!mem.eql(u8, Context.GLOBAL_TAG, scope.tag)) {
            self.reportError(.{ .lineIndex = decl.lineIndex, .type = .NestedFunction });
            return;
        }
        self.resolveBlockIdentifiers(context, body);
    }
}

fn resolveVarDecl(self: *Semantic, context: *Context, decl: *VarDecl) void {
    const name = decl.name; // cache the parsed name

    if (context.getScope().identifiers.get(name)) |entry| {
        if (entry.fromCurrentScope) {
            self.reportError(.{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = decl.name });
            return;
        }
    }

    decl.unique = self.generateUnique(context, name); // add a unique tag to the name
    // add the parsed name and now unique name as a key-value pair
    context.getScope().identifiers.put(name, .{ .unique = decl.unique.? }) catch allocError();

    if (decl.init) |*initExpr| {
        self.resolveExpression(context, initExpr);
    }
}

fn resolveBlockIdentifiers(self: *Semantic, context: *Context, block: *Block) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| self.resolveStatementIdentifiers(context, stmt),
            .Declaration => |*decl| self.resolveDeclaration(context, decl),
        }
    }
}

/// On first-pass:
///   1) ensure that identifiers are declared, in scope, and resolve them to unique names
///   2) collect all declared labels into a map structure for resolution in pass 2 (since
///      labels may be used before they're declared, i.e. gotos)
///   3) collect all individual cases into their respective switch statements for use in TAC gen
fn resolveStatementIdentifiers(self: *Semantic, context: *Context, statement: *Statement) void {
    switch (statement.*) {
        .Compound => |*compound| {
            compound.tag = self.generateUnique(context, "compound");

            context.pushScope(.Block, compound.tag.?);
            defer context.popScope();

            self.resolveBlockIdentifiers(context, compound);
        },
        .Return => |*ret| self.resolveExpression(context, &ret.expr),
        .Expression => |*expr| self.resolveExpression(context, expr),
        .If => |*ifStmt| {
            self.resolveExpression(context, &ifStmt.condition);
            self.resolveStatementIdentifiers(context, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |*elseStmt| {
                self.resolveStatementIdentifiers(context, elseStmt.*);
            }
        },
        .Label => |*lbl| {
            const name = statement.Label.name;
            const unique = self.generateUnique(context, name);

            context.addNewLabel(name, unique);

            lbl.tag = unique;
            self.resolveStatementIdentifiers(context, lbl.body);
        },
        .Break => |*brk| if (context.getBreakTag()) |tag| {
            brk.tag = tag;
        } else {
            self.reportError(.{ .lineIndex = brk.lineIndex, .type = .Break });
        },
        .Continue => |*cont| if (context.getContinueTag()) |tag| {
            cont.tag = tag;
        } else {
            self.reportError(.{ .lineIndex = cont.lineIndex, .type = .Continue });
        },
        .DoWhile => |*doWhl| {
            doWhl.tag = self.generateUnique(context, "doWhile");

            context.pushScope(.Loop, doWhl.tag.?);

            self.resolveStatementIdentifiers(context, doWhl.body);
            self.resolveExpression(context, &doWhl.cond);
        },
        .While => |*whl| {
            self.resolveExpression(context, &whl.cond);

            whl.tag = self.generateUnique(context, "while");

            context.pushScope(.Loop, whl.tag.?);
            self.resolveStatementIdentifiers(context, whl.body);
        },
        .For => |*f| {
            f.tag = self.generateUnique(context, "for");

            context.pushScope(.Loop, f.tag.?);
            defer context.popScope();

            switch (f.init) {
                .Declaration => |*decl| self.resolveDeclaration(context, decl),
                .Expression => if (f.init.Expression) |*expr| {
                    self.resolveExpression(context, expr);
                },
            }
            if (f.cond) |*cond| self.resolveExpression(context, cond);
            if (f.post) |*post| self.resolveExpression(context, post);

            self.resolveStatementIdentifiers(context, f.body);
        },
        .Goto, .Null => {}, // gotos are resolved on the second pass
        .Switch => |*swtch| {
            self.resolveExpression(context, &swtch.cond);

            swtch.tag = self.generateUnique(context, "switch");

            context.pushScope(.Switch, swtch.tag.?);
            defer context.popScope();

            context.switchTags.put(swtch.tag.?, swtch) catch allocError();

            self.resolveStatementIdentifiers(context, swtch.body);
        },
        .Case => |*case| {
            if (context.getSwitchTag()) |switchTag| {
                const cond = if (case.cond) |cond| cond.Constant else "default";
                case.tag = self.allocator.print("{s}.{s}", .{switchTag, cond}) catch allocError();

                const parentSwitch = context.switchTags.get(switchTag) orelse unreachable;
                parentSwitch.addCase(self.allocator, case) catch self.reportError(.{ .lineIndex = case.lineIndex, .type = .CaseDuplicate, });

                if (case.body) |body| self.resolveStatementIdentifiers(context, body);
            } else {
                self.reportError(.{ .lineIndex = case.lineIndex, .type = .CaseOutside });
            }
        },
    }
}

fn resolveExpression(self: *Semantic, context: *Context, expr: *Expression) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.lhs.* != .Var) {
                self.reportError(.{ .lineIndex = assign.lineIndex, .type = .NotAssignable });
            }

            self.resolveExpression(context, assign.lhs);
            self.resolveExpression(context, assign.rhs);
        },
        .Binary => |*binary| {
            self.resolveExpression(context, binary.left);
            self.resolveExpression(context, binary.right);
        },
        .Var => |*v| {
            if (context.getScope().identifiers.get(v.name)) |entry| {
                v.name = entry.unique;
            } else {
                self.reportError(.{ .lineIndex = v.lineIndex, .type = .UndeclaredIdentifier, .name = v.name });
            }
        },
        .Unary => |unary| {
            switch (unary.operator) {
                .Inc, .Dec => {
                    if (unary.operand.* != .Var) {
                        self.reportError(.{ .lineIndex = unary.lineIndex, .type = .NotAssignable });
                    }
                },
                else => {},
            }
            self.resolveExpression(context, unary.operand);
        },
        .Constant => {},
        .Ternary => |*ternary| {
            self.resolveExpression(context, ternary.condition);
            self.resolveExpression(context, ternary.thenStmt);
            self.resolveExpression(context, ternary.elseStmt);
        },
        .FunctionCall => |*func| {
            const scope = context.getScope();
            if (scope.identifiers.get(func.name)) |*entry| {
                // The 'name' and 'unique' attributes should be the same for
                // externally linked identifiers in a valid program, but may
                // differ for invalid (e.g. calling a variable identifier as
                // a function). This will be detected during type-checking
                func.name = entry.unique;

                for (func.args) |*arg| {
                    self.resolveExpression(context, arg);
                }
            } else {
                self.reportError(.{ .lineIndex = func.lineIndex, .type = .UndeclaredIdentifier, .name = func.name, });
            }
        },
    }
}

fn reportError(self: *Semantic, err: SemanticError) void {
    switch (err.type) {
        .Break => std.log.err("'break' statement outside of loop or switch statement", .{}),
        .CaseOutside => std.log.err("'case' or 'default' label outside of switch statement", .{}),
        .CaseDuplicate => std.log.err("Duplicate 'case' or 'default'", .{}),
        .Continue => std.log.err("'continue' statement outside of loop statement", .{}),
        .NotAssignable => std.log.err("Expression is not an assignable lvalue", .{}),
        .NestedFunction => std.log.err("Function definitions may only exist at the top level", .{}),
        .OrphanLabel => std.log.err("Label '{s}' outside of function scope", .{err.name.?}),
        .Redeclaration => std.log.err("Redeclaration of '{s}'", .{err.name.?}),
        .UndeclaredIdentifier => std.log.err("Use of undeclared identifier '{s}'", .{err.name.?}),
    }
    const index = err.lineIndex;
    std.log.err(" {d} | {s}\n", .{ index + 1, self.lines[index] });

    self.errorFlag = true;
}

fn generateUnique(self: *Semantic, context: *Context, name: []const u8) []u8 {
    const scope = context.getScope();
    const unique = self.allocator.print("{s}.{s}.{d}", .{ scope.tag, name, context.counter }) catch allocError();
    context.counter += 1;

    return unique;
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
