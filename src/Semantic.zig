// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const Block = Parser.Block;
const Declaration = Parser.Declaration;
const FunDecl = Parser.FunDecl;
const VarDecl = Parser.VarDecl;
const Statement = Parser.Statement;
const Expression = Parser.Expression;
const Switch = Parser.Switch;

const Semantic = @This();

const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;

const AST = Parser.AST;

allocator: Allocator,
lines: [][]const u8,
idCounter: usize = 0,
errorFlag: bool = false,
switches: std.StringHashMap(*Switch),

const SemanticError = struct {
    lineIndex: usize,
    type: enum {
        Break,
        CaseOutside,
        CaseDuplicate,
        Continue,
        Redeclaration,
        UndeclaredIdentifier,
        NestedFunction,
        NotAssignable,
    },
    name: ?[]const u8 = null,
};

pub fn init(allocator: Allocator, lines: [][]const u8) Semantic {
    return .{ .allocator = allocator, .switches = .init(allocator), .lines = lines };
}

pub fn deinit(self: *Semantic) void {
    self.switches.deinit();
}

pub fn resolve(self: *Semantic, ast: *AST) void {
    var context: Context = .init(self.allocator);
    defer context.deinit();

    resolveFirstPass(self, ast, &context);
    resolveSecondPass(self, ast, &context);

    if (self.errorFlag) std.process.exit(1);
}

fn resolveFirstPass(self: *Semantic, ast: *AST, context: *Context) void {
    for (ast.tree.functions) |*function| self.resolveFunDecl(function, context);
}

fn resolveSecondPass(self: *Semantic, ast: *AST, context: *Context) void {
    for (ast.tree.functions) |function| {
        if (function.body) |body| {
            for (body.items) |*block| {
                switch (block.*) {
                    .Statement => |*statement| self.labelResolutionPass(statement, context),
                    else => {},
                }
            }
        }
    }
}

fn resolveDeclaration(self: *Semantic, decl: *Declaration, context: *Context) void {
    switch (decl.*) {
        .FunDecl => |*funDecl| self.resolveFunDecl(funDecl, context),
        .VarDecl => |*varDecl|  self.resolveVarDecl(varDecl, context),
    }
}

fn resolveFunDecl(self: *Semantic, decl: *FunDecl, context: *Context) void {
    const scope = context.*.getScopeMut();
    if (scope.*.identifiers.get(decl.name)) |entry| {
        if (entry.fromCurrentScope and !entry.hasLinkage) {
            self.reportError(.{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = decl.name });
            return;
        }
    }

    scope.*.identifiers.put(decl.name, .{
        .unique = decl.name,
        .fromCurrentScope = true,
        .hasLinkage = true
    }) catch allocError();


    context.pushScope(.Function, decl.name);
    defer context.popScope();

    for (decl.params) |*param| {
        self.resolveVarDecl(param, context);
    }

    if (decl.body) |*body| {
        if (!std.mem.eql(u8, "_global", scope.tag)) {
            self.reportError(.{ .lineIndex = decl.lineIndex, .type = .NestedFunction });
            return;
        }
        self.resolveBlockIdentifiers(body, context);
    }
}

fn resolveVarDecl(self: *Semantic, decl: *VarDecl, context: *Context) void {
    const name = decl.name; // cache the parsed name
    if (context.getScope().identifiers.get(name)) |entry| {
        if (entry.fromCurrentScope) {
            self.reportError(.{ .lineIndex = decl.lineIndex, .type = .Redeclaration, .name = decl.name });
            return;
        }
    }

    decl.name = self.generateUnique(context.getScope().tag, name); // add a unique tag to the name
    // add the parsed name and now unique name as a key-value pair
    context.*.getScopeMut().identifiers.put(name, .{ .unique = decl.name }) catch allocError();

    if (decl.init) |*initExpr| {
        self.resolveExpression(initExpr, context);
    }
}

fn resolveBlockIdentifiers(self: *Semantic, block: *Block, context: *Context) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| self.identifierResolutionPass(stmt, context),
            .Declaration => |*decl| self.resolveDeclaration(decl, context),
        }
    }
}

fn resolveBlockLabels(self: *Semantic, block: *Block, context: *Context) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| self.labelResolutionPass(stmt, context),
            .Declaration => {},
        }
    }
}

/// On first-pass:
///   1) ensure that identifiers are declared, in scope, and resolve them to unique names
///   2) collect all declared labels into a map structure for resolution in pass 2 (since
///      labels may be used before they're declared, i.e. gotos)
///   3) collect all individual cases into their respective switch statements for use in TAC gen
fn identifierResolutionPass(self: *Semantic, statement: *Statement, context: *Context) void {
    switch (statement.*) {
        .Compound => |*compound| {
            compound.*.tag = self.generateUnique(context.getScope().tag, "compound");

            context.pushScope(.Block, compound.tag.?);
            defer context.popScope();

            self.resolveBlockIdentifiers(compound, context);
        },
        .Return => |*ret| self.resolveExpression(&ret.expr, context),
        .Expression => |*expr| self.resolveExpression(expr, context),
        .If => |*ifStmt| {
            self.resolveExpression(&ifStmt.condition, context);
            self.identifierResolutionPass(ifStmt.thenStmt, context);
            if (ifStmt.elseStmt) |*elseStmt| {
                self.identifierResolutionPass(elseStmt.*, context);
            }
        },
        .Label => |*lbl| {
            const name = statement.Label.name;
            if (context.labels.get(name)) |entry| {
                if (entry.fromCurrentScope) {
                    self.reportError(.{ .lineIndex = lbl.lineIndex, .type = .Redeclaration, .name = name });
                    return;
                }
            }
            lbl.*.tag = self.generateUnique(context.getScope().tag, name);
            context.labels.put(name, .{ .unique = lbl.tag.? }) catch allocError();


            self.identifierResolutionPass(lbl.body, context);
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
            doWhl.tag = self.generateUnique(context.getScope().tag, "doWhile");

            context.pushScope(.Loop, doWhl.tag.?);

            self.identifierResolutionPass(doWhl.body, context);
            self.resolveExpression(&doWhl.cond, context);
        },
        .While => |*whl| {
            self.resolveExpression(&whl.cond, context);

            whl.*.tag = self.generateUnique(context.getScope().tag, "while");

            context.pushScope(.Loop, whl.tag.?);
            self.identifierResolutionPass(whl.body, context);
        },
        .For => |*f| {
            f.*.tag = self.generateUnique(context.getScope().tag, "for");

            context.pushScope(.Loop, f.tag.?);
            defer context.popScope();

            switch (f.init) {
                .Declaration => |*decl| self.resolveDeclaration(decl, context),
                .Expression => if (f.init.Expression) |*expr| {
                    self.resolveExpression(expr, context);
                },
            }
            if (f.cond) |*cond| self.resolveExpression(cond, context);
            if (f.post) |*post| self.resolveExpression(post, context);

            self.identifierResolutionPass(f.body, context);
        },
        .Goto, .Null => {}, // gotos are resolved on the second pass
        .Switch => |*swtch| {
            self.resolveExpression(&swtch.cond, context);

            swtch.tag = self.generateUnique(context.getScope().tag, "switch");

            context.pushScope(.Switch, swtch.tag.?);
            defer context.popScope();

            self.switches.put(swtch.tag.?, swtch) catch allocError();

            self.identifierResolutionPass(swtch.body, context);
        },
        .Case => |*case| if (context.getSwitchTag()) |switchTag| {
            const cond = if (case.cond) |cond| cond.Constant else "default";
            case.*.tag = self.allocator.print("{s}.{s}", .{switchTag, cond}) catch allocError();

            const parentSwitch = self.switches.get(switchTag) orelse unreachable;
            parentSwitch.*.addCase(case) catch self.reportError(.{ .lineIndex = case.lineIndex, .type = .CaseDuplicate, });

            if (case.body) |body| self.identifierResolutionPass(body, context);
        } else {
            self.reportError(.{ .lineIndex = case.lineIndex, .type = .CaseOutside });
        },
    }
}

/// On second pass: resolve all labels to their unique names, using the map from the 1st pass
fn labelResolutionPass(self: *Semantic, statement: *Statement, context: *Context) void {
    switch (statement.*) {
        .Compound => |*compound| self.resolveBlockLabels(compound, context),
        .Goto => |*goto| {
            if (context.labels.get(goto.*.target)) |entry| {
                goto.*.target = entry.unique;
            } else {
                self.reportError(.{ .lineIndex = goto.*.lineIndex, .type = .UndeclaredIdentifier, .name = goto.*.target });
            }
        },
        .If => |*ifStmt| {
            self.labelResolutionPass(ifStmt.thenStmt, context);
            if (ifStmt.elseStmt) |*elseStmt| self.labelResolutionPass(elseStmt.*, context);
        },
        .Switch => |*swtch| self.labelResolutionPass(swtch.body, context),
        .Case => |*case| if (case.body) |body| self.labelResolutionPass(body, context),
        .Label => |*label| self.labelResolutionPass(label.body, context),
        .DoWhile, => |*loop| self.labelResolutionPass(loop.body, context),
        .For, => |*loop| self.labelResolutionPass(loop.body, context),
        .While => |*loop| self.labelResolutionPass(loop.body, context),
        else => {},
    }
}

fn resolveExpression(self: *Semantic, expr: *Expression, context: *Context) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.lhs.* != .Var) {
                self.reportError(.{ .lineIndex = assign.lineIndex, .type = .NotAssignable });
            }

            self.resolveExpression(assign.lhs, context);
            self.resolveExpression(assign.rhs, context);
        },
        .Binary => |*binary| {
            self.resolveExpression(binary.left, context);
            self.resolveExpression(binary.right, context);
        },
        .Var => |*v| {
            if (context.getScope().identifiers.get(v.*.name)) |entry| {
                v.*.name = entry.unique;
            } else {
                self.reportError(.{ .lineIndex = v.*.lineIndex, .type = .UndeclaredIdentifier, .name = v.*.name });
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
            self.resolveExpression(unary.operand, context);
        },
        .Constant => {},
        .Ternary => |*ternary| {
            self.resolveExpression(ternary.condition, context);
            self.resolveExpression(ternary.thenStmt, context);
            self.resolveExpression(ternary.elseStmt, context);
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
                    self.resolveExpression(arg, context);
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
        .Redeclaration => std.log.err("Redeclaration of '{s}'", .{err.name.?}),
        .UndeclaredIdentifier => std.log.err("Use of undeclared identifier '{s}'", .{err.name.?}),
    }
    const index = err.lineIndex;
    std.log.err(" {d} | {s}\n", .{ index + 1, self.lines[index] });

    self.errorFlag = true;
}

fn generateUnique(self: *Semantic, scope: []const u8, name: []const u8) []u8 {
    defer self.idCounter += 1;
    return self.allocator.print("{s}.{s}.{d}", .{ scope, name, self.idCounter }) catch allocError();
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
