const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const Parser = @import("../Parser.zig");
const Declaration = Parser.Declaration;
const Block = Parser.Block;
const FunDecl = Parser.FunDecl;
const VarDecl = Parser.VarDecl;
const Statement = Parser.Statement;
const Expression = Parser.Expression;

const Context = @import("Context.zig");

pub fn run(allocator: Allocator, context: *Context, tree: *Parser.AST) void {
    resolveProgram(allocator, context, tree);
}

fn resolveProgram(allocator: Allocator, context: *Context, tree: *Parser.AST) void {
    for (tree.functions) |*funDecl| {
        resolveFunDecl(allocator, context, funDecl);
    }
}

fn resolveDeclaration(allocator: Allocator, context: *Context, decl: *Declaration) void {
    switch (decl.*) {
        .FunDecl => |*funDecl| resolveFunDecl(allocator, context, funDecl),
        .VarDecl => |*varDecl| resolveVarDecl(allocator, context, varDecl),
    }
}

fn resolveFunDecl(allocator: Allocator, context: *Context, decl: *FunDecl) void {
    const scope = context.getScope();
    if (scope.identifiers.get(decl.name)) |entry| {
        if (entry.fromCurrentScope and !entry.hasLinkage) {
            context.err.report(.Redeclaration, decl.lineIndex, decl.name);
            return;
        }
    }

    scope.identifiers.put(decl.name, .{ .unique = decl.name, .fromCurrentScope = true, .hasLinkage = true }) catch allocError();

    context.function = decl.name;
    defer context.function = null;

    context.pushScope(.Function, decl.name);
    defer context.popScope();

    for (decl.params) |*param| {
        resolveVarDecl(allocator, context, param);
    }

    if (decl.body) |*body| {
        if (!mem.eql(u8, Context.GLOBAL_TAG, scope.tag)) {
            context.err.report(.NestedFunction, decl.lineIndex, null);
            return;
        }
        resolveBlockIdentifiers(allocator, context, body);
    }
}

fn resolveVarDecl(allocator: Allocator, context: *Context, decl: *VarDecl) void {
    const name = decl.name; // cache the parsed name

    if (context.getScope().identifiers.get(name)) |entry| {
        if (entry.fromCurrentScope) {
            context.err.report(.Redeclaration, decl.lineIndex, decl.name);
            return;
        }
    }

    decl.unique = generateUnique(allocator, context, name); // add a unique tag to the name
    // add the parsed name and now unique name as a key-value pair
    context.getScope().identifiers.put(name, .{ .unique = decl.unique.? }) catch allocError();

    if (decl.init) |*initExpr| {
        resolveExpression(allocator, context, initExpr);
    }
}

fn resolveBlockIdentifiers(allocator: Allocator, context: *Context, block: *Block) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| resolveStatementIdentifiers(allocator, context, stmt),
            .Declaration => |*decl| resolveDeclaration(allocator, context, decl),
        }
    }
}

/// On first-pass:
///   1) ensure that identifiers are declared, in scope, and resolve them to unique names
///   2) collect all declared labels into a map structure for resolution in pass 2 (since
///      labels may be used before they're declared, i.e. gotos)
///   3) collect all individual cases into their respective switch statements for use in TAC gen
fn resolveStatementIdentifiers(allocator: Allocator, context: *Context, statement: *Statement) void {
    switch (statement.*) {
        .Compound => |*compound| {
            compound.tag = generateUnique(allocator, context, "compound");

            context.pushScope(.Block, compound.tag.?);
            defer context.popScope();

            resolveBlockIdentifiers(allocator, context, compound);
        },
        .Return => |*ret| resolveExpression(allocator, context, &ret.expr),
        .Expression => |*expr| resolveExpression(allocator, context, expr),
        .If => |*ifStmt| {
            resolveExpression(allocator, context, &ifStmt.condition);
            resolveStatementIdentifiers(allocator, context, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |*elseStmt| {
                resolveStatementIdentifiers(allocator, context, elseStmt.*);
            }
        },
        .Label => |*lbl| {
            const unique = generateUnique(allocator, context, lbl.name);
            context.addNewLabel(lbl, unique);

            resolveStatementIdentifiers(allocator, context, lbl.body);
        },
        .Break => |*brk| if (context.getBreakTag()) |tag| {
            brk.tag = tag;
        } else {
            context.err.report(.Break, brk.lineIndex, null);
        },
        .Continue => |*cont| if (context.getContinueTag()) |tag| {
            cont.tag = tag;
        } else {
            context.err.report(.Continue, cont.lineIndex, null);
        },
        .DoWhile => |*doWhl| {
            doWhl.tag = generateUnique(allocator, context, "doWhile");

            context.pushScope(.Loop, doWhl.tag.?);

            resolveStatementIdentifiers(allocator, context, doWhl.body);
            resolveExpression(allocator, context, &doWhl.cond);
        },
        .While => |*whl| {
            resolveExpression(allocator, context, &whl.cond);

            whl.tag = generateUnique(allocator, context, "while");

            context.pushScope(.Loop, whl.tag.?);
            resolveStatementIdentifiers(allocator, context, whl.body);
        },
        .For => |*f| {
            f.tag = generateUnique(allocator, context, "for");

            context.pushScope(.Loop, f.tag.?);
            defer context.popScope();

            switch (f.init) {
                .Declaration => |*decl| resolveDeclaration(allocator, context, decl),
                .Expression => if (f.init.Expression) |*expr| {
                    resolveExpression(allocator, context, expr);
                },
            }
            if (f.cond) |*cond| resolveExpression(allocator, context, cond);
            if (f.post) |*post| resolveExpression(allocator, context, post);

            resolveStatementIdentifiers(allocator, context, f.body);
        },
        .Goto, .Null => {}, // gotos are resolved on the second pass
        .Switch => |*swtch| {
            resolveExpression(allocator, context, &swtch.cond);

            swtch.tag = generateUnique(allocator, context, "switch");

            context.pushScope(.Switch, swtch.tag.?);
            defer context.popScope();

            context.switchTags.put(swtch.tag.?, swtch) catch allocError();

            resolveStatementIdentifiers(allocator, context, swtch.body);
        },
        .Case => |*case| {
            if (context.getSwitchTag()) |switchTag| {
                const cond = if (case.cond) |cond| cond.Constant else "default";
                case.tag = allocator.print("{s}.{s}", .{ switchTag, cond }) catch allocError();

                const parentSwitch = context.switchTags.get(switchTag) orelse unreachable;
                parentSwitch.addCase(allocator, case) catch {
                    context.err.report(.CaseDuplicate, case.lineIndex, null);
                };

                if (case.body) |body| resolveStatementIdentifiers(allocator, context, body);
            } else {
                context.err.report(.CaseOutside, case.lineIndex, null);
            }
        },
    }
}

fn resolveExpression(allocator: Allocator, context: *Context, expr: *Expression) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            if (assign.lhs.* != .Var) {
                context.err.report(.NotAssignable, assign.lineIndex, null);
            }

            resolveExpression(allocator, context, assign.lhs);
            resolveExpression(allocator, context, assign.rhs);
        },
        .Binary => |*binary| {
            resolveExpression(allocator, context, binary.left);
            resolveExpression(allocator, context, binary.right);
        },
        .Var => |*v| {
            if (context.getScope().identifiers.get(v.name)) |entry| {
                v.name = entry.unique;
            } else {
                context.err.report(.UndeclaredIdentifier, v.lineIndex, v.name);
            }
        },
        .Unary => |unary| {
            switch (unary.operator) {
                .Inc, .Dec => {
                    if (unary.operand.* != .Var) {
                        context.err.report(.NotAssignable, unary.lineIndex, null);
                    }
                },
                else => {},
            }
            resolveExpression(allocator, context, unary.operand);
        },
        .Constant => {},
        .Ternary => |*ternary| {
            resolveExpression(allocator, context, ternary.condition);
            resolveExpression(allocator, context, ternary.thenStmt);
            resolveExpression(allocator, context, ternary.elseStmt);
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
                    resolveExpression(allocator, context, arg);
                }
            } else {
                context.err.report(.UndeclaredIdentifier, func.lineIndex, func.name);
            }
        },
    }
}

fn generateUnique(allocator: Allocator, context: *Context, name: []const u8) []u8 {
    const scope = context.getScope();
    const unique = allocator.print("{s}.{s}.{d}", .{ scope.tag, name, context.counter }) catch allocError();
    context.counter += 1;

    return unique;
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
