const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;

const Parser = @import("../Parser.zig");
const Declaration = Parser.Declaration;
const Block = Parser.Block;
const FunDecl = Parser.FunDecl;
const VarDecl = Parser.VarDecl;
const Statement = Parser.Statement;
const Expression = Parser.Expression;

const Context = @import("Context.zig");

pub fn run(allocator: Allocator, context: *Context, tree: *Parser.AST) Allocator.Error!void {
    try resolveProgram(allocator, context, tree);
}

fn resolveProgram(allocator: Allocator, context: *Context, tree: *Parser.AST) Allocator.Error!void {
    for (tree.declarations) |*decl| {
        switch (decl.*) {
            .FunDecl => |*funDecl| try resolveFunDecl(allocator, context, funDecl),
            .VarDecl => |*varDecl| try resolveFileScopeVarDecl(context, varDecl),
        }
    }
}

fn resolveDeclaration(allocator: Allocator, context: *Context, decl: *Declaration) Allocator.Error!void {
    switch (decl.*) {
        .FunDecl => |*funDecl| try resolveFunDecl(allocator, context, funDecl),
        .VarDecl => |*varDecl| try resolveLocalVarDecl(allocator, context, varDecl),
    }
}

fn resolveFunDecl(allocator: Allocator, context: *Context, decl: *FunDecl) Allocator.Error!void {
    var outerScope = context.getScope();
    // Static storage class only allowed for function at file-scope
    if (outerScope.type != .File and decl.storageClass == .Static) {
        context.err.report(.BlockScopeStaticFunDecl, decl.lineIndex, null);
        return;
    }

    if (outerScope.identifiers.get(decl.name)) |entry| {
        if (entry.fromCurrentScope and !entry.hasLinkage) {
            context.err.report(.Redeclaration, decl.lineIndex, decl.name);
            return;
        }
    }

    try outerScope.identifiers.put(decl.name, .{ .unique = decl.name, .fromCurrentScope = true, .hasLinkage = true });

    context.function = decl.name;
    defer context.function = null;

    try context.pushScope(.Function, decl.name);
    defer context.popScope();
    const innerScope = context.getScope();

    for (decl.params) |*param| {
        if (innerScope.identifiers.get(param.*)) |entry| {
            if (entry.fromCurrentScope) {
                context.err.report(.Redeclaration, decl.lineIndex, decl.name);
                return;
            }
        }
        const unique = try generateUnique(allocator, context, param.*);
        try innerScope.identifiers.put(param.*, .{ .unique = unique });
        param.* = unique;
    }

    if (decl.body) |*body| {
        // Function definitions no allowed outside of file scope
        if (!mem.eql(u8, Context.FILE_SCOPE, outerScope.tag)) {
            context.err.report(.NestedFunction, decl.lineIndex, null);
            return;
        }
        try resolveBlockIdentifiers(allocator, context, body);
    }
    decl.resolved = true;
}

fn resolveVarDecl(allocator: Allocator, context: *Context, decl: *VarDecl) Allocator.Error!void {
    if (context.tag == Context.FILE_SCOPE) {
        resolveFileScopeVarDecl(context, decl);
    } else {
        try resolveLocalVarDecl(allocator, context, decl);
    }
}

fn resolveFileScopeVarDecl(context: *Context, decl: *VarDecl) Allocator.Error!void {
    // Since file-scope declaration must be initialized with constant values (and
    // 'constexpr' is not currently supported), we don't need to resolve anything
    // int the initialization if it exists
    const scope = context.getScope();
    try scope.identifiers.put(decl.name, .{ .unique = decl.name, .hasLinkage = true });
}

fn resolveLocalVarDecl(allocator: Allocator, context: *Context, decl: *VarDecl) Allocator.Error!void {
    const name = decl.name; // cache the parsed name

    if (context.getScope().identifiers.get(name)) |entry| {
        if (entry.fromCurrentScope) {
            if (!entry.hasLinkage or decl.storageClass != .Extern) {
                context.err.report(.Redeclaration, decl.lineIndex, decl.name);
                return;
            }
        }
    }

    const scope = context.getScope();
    if (decl.storageClass == .Extern) {
        try scope.identifiers.put(decl.name, .{ .unique = decl.name, .hasLinkage = true });
        return;
    }

    decl.unique = try generateUnique(allocator, context, name);
    try scope.identifiers.put(name, .{ .unique = decl.unique.? });

    if (decl.init) |*initExpr| {
        resolveExpression(allocator, context, initExpr);
    }
}

fn resolveBlockIdentifiers(allocator: Allocator, context: *Context, block: *Block) Allocator.Error!void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| try resolveStatementIdentifiers(allocator, context, stmt),
            .Declaration => |*decl| try resolveDeclaration(allocator, context, decl),
        }
    }
}

/// On first-pass:
///   1) ensure that identifiers are declared, in scope, and resolve them to unique names
///   2) collect all declared labels into a map structure for resolution in pass 2 (since
///      labels may be used before they're declared, i.e. gotos)
///   3) collect all individual cases into their respective switch statements for use in TAC gen
fn resolveStatementIdentifiers(allocator: Allocator, context: *Context, statement: *Statement) Allocator.Error!void {
    switch (statement.*) {
        .Compound => |*compound| {
            compound.tag = try generateUnique(allocator, context, "compound");

            try context.pushScope(.Block, compound.tag.?);
            defer context.popScope();

            try resolveBlockIdentifiers(allocator, context, compound);
        },
        .Return => |*ret| resolveExpression(allocator, context, &ret.expr),
        .Expression => |*expr| resolveExpression(allocator, context, expr),
        .If => |*ifStmt| {
            resolveExpression(allocator, context, &ifStmt.condition);
            try resolveStatementIdentifiers(allocator, context, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |*elseStmt| {
                try resolveStatementIdentifiers(allocator, context, elseStmt.*);
            }
        },
        .Label => |*lbl| {
            const unique = try generateUnique(allocator, context, lbl.name);
            try context.addNewLabel(lbl, unique);

            try resolveStatementIdentifiers(allocator, context, lbl.body);
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
            doWhl.tag = try generateUnique(allocator, context, "doWhile");

            try context.pushScope(.Loop, doWhl.tag.?);

            try resolveStatementIdentifiers(allocator, context, doWhl.body);
            resolveExpression(allocator, context, &doWhl.cond);
        },
        .While => |*whl| {
            resolveExpression(allocator, context, &whl.cond);

            whl.tag = try generateUnique(allocator, context, "while");

            try context.pushScope(.Loop, whl.tag.?);
            try resolveStatementIdentifiers(allocator, context, whl.body);
        },
        .For => |*f| {
            f.tag = try generateUnique(allocator, context, "for");

            try context.pushScope(.Loop, f.tag.?);
            defer context.popScope();

            switch (f.init) {
                .Declaration => |*decl| try resolveDeclaration(allocator, context, decl),
                .Expression => if (f.init.Expression) |*expr| {
                    resolveExpression(allocator, context, expr);
                },
            }
            if (f.cond) |*cond| resolveExpression(allocator, context, cond);
            if (f.post) |*post| resolveExpression(allocator, context, post);

            try resolveStatementIdentifiers(allocator, context, f.body);
        },
        .Goto, .Null => {}, // gotos are resolved on the second pass
        .Switch => |*sw| {
            resolveExpression(allocator, context, &sw.cond);

            sw.tag = try generateUnique(allocator, context, "switch");

            try context.switches.append(allocator, sw);
            defer _ = context.switches.pop();

            try context.pushScope(.Switch, sw.tag.?);
            defer context.popScope();

            try resolveStatementIdentifiers(allocator, context, sw.body);
        },
        .Case => |*case| {
            if (context.switches.last()) |parentSwitch| {
                case.parent = parentSwitch;

                if (case.body) |body| try resolveStatementIdentifiers(allocator, context, body);
            } else {
                context.err.report(.OrphanCase, case.lineIndex, null);
            }
        },
    }
}

fn resolveExpression(allocator: Allocator, context: *Context, expr: *Expression) void {
    switch (expr.*) {
        .Assignment => |*assign| {
            resolveExpression(allocator, context, assign.rhs);
            if (assign.lhs.* != .Var) {
                context.err.report(.NotAssignable, assign.lineIndex, null);
                return;
            }
            resolveExpression(allocator, context, assign.lhs);
        },
        .Binary => |*binary| {
            resolveExpression(allocator, context, binary.left);
            resolveExpression(allocator, context, binary.right);
        },
        .Constant => {},
        .Cast => |*cast| resolveExpression(allocator, context, cast.exp),
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
        .Ternary => |*ternary| {
            resolveExpression(allocator, context, ternary.condition);
            resolveExpression(allocator, context, ternary.thenExpr);
            resolveExpression(allocator, context, ternary.elseExpr);
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
        .Var => |*v| {
            if (context.getScope().identifiers.get(v.name)) |entry| {
                v.name = entry.unique;
            } else {
                context.err.report(.UndeclaredIdentifier, v.lineIndex, v.name);
            }
        },
    }
}

fn generateUnique(allocator: Allocator, context: *Context, name: []const u8) Allocator.Error![]u8 {
    const scope = context.getScope();
    const unique = try allocator.print("{s}.{s}.{d}", .{ scope.tag, name, context.counter });
    context.counter += 1;

    return unique;
}
