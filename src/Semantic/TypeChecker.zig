const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const process = std.process;

const Parser = @import("../Parser.zig");
const AST = Parser.AST;
const Block = Parser.Block;
const Declaration = Parser.Declaration;
const Expression = Parser.Expression;
const FunDecl = Parser.FunDecl;
const Statement = Parser.Statement;
const VarDecl = Parser.VarDecl;

const Error = @import("Error.zig");

// Rather than pass around an entire Context, to keep things simple the error
// reporting will be handled by a global object. TODO: maybe revisit for a better
// solution
var ErrorReporter: *Error.Reporter = undefined;

const TypeChecker = @This();

const Int = struct {};

const FunType = struct {
    type: Int,
    nParams: usize,
};

const TypeTag = enum { Int, FunType };
const Type = union(TypeTag) {
    Int: Int,
    FunType: FunType,
};

const FunAttr = struct {
    defined: bool,
    global: bool,
};
const Attrs = union {
    const Initial = struct { int: usize };
    const Tentative = struct {};

    const InitialValueTag = enum { Initial, Tentative };
    const InitialValue = union(InitialValueTag) {
        Initial: Initial,
        Tentative: Tentative,
    };

    Fun: struct {
        defined: bool,
        global: bool,
    },
    Static: struct {
        initialValue: ?InitialValue,
        global: bool,
    },
    Local: struct {},
};

const Entry = struct {
    type: Type,
    attrs: Attrs,
};

const SymbolTable = StringHashMap(Entry);

pub fn run(allocator: Allocator, errorReporter: *Error.Reporter, tree: *AST) void {
    ErrorReporter = errorReporter;

    var symbols: SymbolTable = .init(allocator);
    defer symbols.deinit();

    for (tree.declarations) |decl| {
        switch (decl) {
            .FunDecl => typeCheckFunDecl(&symbols, decl.FunDecl),
            .VarDecl => typeCheckFileScopeVarDecl(&symbols, decl.VarDecl),
        }
    }
}

fn typeCheckLocalDeclaration(symbols: *SymbolTable, decl: Declaration) void {
    switch (decl) {
        .FunDecl => |funDecl| typeCheckFunDecl(symbols, funDecl),
        .VarDecl => |varDecl| typeCheckLocalVarDecl(symbols, varDecl),
    }
}

fn typeCheckFunDecl(symbols: *SymbolTable, decl: FunDecl) void {
    const funType: FunType = .{ .type = .{}, .nParams = decl.params.len };
    var isDefined: bool = decl.body != null;
    var isGlobal: bool = decl.storageClass != .Static;

    if (symbols.get(decl.name)) |entry| {
        if (entry.type != .FunType or entry.type.FunType.nParams != funType.nParams) {
            ErrorReporter.report(.ConflictingFunctions, decl.lineIndex, decl.name);
            return;
        }

        isDefined = entry.attrs.Fun.defined;
        if (isDefined and decl.body != null) {
            ErrorReporter.report(.Redeclaration, decl.lineIndex, decl.name);
            return;
        }

        isGlobal = entry.attrs.Fun.global;
        if (isGlobal and decl.storageClass == .Static) {
            ErrorReporter.report(.InvalidStaticDeclaration, decl.lineIndex, decl.name);
            return;
        }
    }

    const attrs: Attrs = .{ .Fun = .{
        .defined = isDefined or decl.body != null,
        .global = isGlobal,
    } };
    symbols.put(decl.name, .{ .type = .{ .FunType = funType }, .attrs = attrs }) catch allocError();

    if (decl.body) |body| {
        for (decl.params) |param| {
            symbols.put(param.unique.?, .{ .type = .Int, .attrs = .{ .Local = .{} } }) catch allocError();
        }
        typeCheckBlock(symbols, body);
    }
}

fn typeCheckFileScopeVarDecl(symbols: *SymbolTable, decl: VarDecl) void {
    var initialValue: ?Attrs.InitialValue = undefined;
    if (decl.init) |init| {
        // TODO: extend initialize to use constant binary and unary expressions
        if (init.Assignment.rhs.* == .Constant) {
            initialValue = .{ .Initial = .{ .int = init.Assignment.rhs.Constant } };
        } else {
            ErrorReporter.report(.NonConstInitializer, decl.lineIndex, decl.name);
            std.process.exit(1);
        }
    } else { // no initializer
        if (decl.storageClass == .Extern) {
            initialValue = null;
        } else {
            initialValue = .{ .Tentative = .{} };
        }
    }

    var isGlobal = decl.storageClass != .Static;
    if (symbols.get(decl.name)) |entry| {
        _ = entry.attrs.Fun catch {};
        // Previous declaration was a function
        if (entry.type != .Int) {
            ErrorReporter.report(.Redeclaration, decl.lineIndex, decl.name);
            return;
        }

        // Ensure this declaration and previous declarations align on linkage
        if (decl.storageClass == .Extern) {
            isGlobal = entry.attrs.Static.global;
        } else if (entry.attrs.Static.global != isGlobal) {
            ErrorReporter.report(.ConflictingLinkage, decl.lineIndex, decl.name);
            return;
        }

        if (entry.attrs.Static.initialValue) |oldInit| {
            if (oldInit == .Initial) { // ensure no redefinitions of global variables
                if (initialValue != null and initialValue.? == .Initial) {
                    ErrorReporter.report(.VariableRedefinition, decl.lineIndex, decl.name);
                    return;
                }
                initialValue = oldInit;
            } else if (oldInit == .Tentative) {
                if (initialValue != null and initialValue.? != .Initial) {
                    initialValue = .Tentative;
                }
            }
        }
    }

    const attrs: Attrs = .{ .Static = .{ .initialValue = initialValue, .global = isGlobal } };
    symbols.put(decl.name, .{ .type = .Int, .attrs = attrs }) catch allocError();
}

fn typeCheckLocalVarDecl(symbols: *SymbolTable, decl: VarDecl) void {
    if (decl.storageClass == .Extern) {
        if (decl.init) |_| {
            ErrorReporter.report(.LocalExternDefined, decl.lineIndex, decl.name);
            return;
        }
        if (symbols.get(decl.name)) |entry| {
            if (entry.type != .Int) {
                ErrorReporter.report(.Redeclaration, decl.lineIndex, decl.name);
                return;
            }
        } else {
            const attrs: Attrs = .{ .Static = .{ .initialValue = null, .global = true } };
            symbols.put(decl.name, .{ .type = .Int, .attrs = attrs }) catch allocError();
        }
    } else if (decl.storageClass == .Static) {
        var initialValue: Attrs.InitialValue = .{ .Initial = .{ .int = 0 } };
        if (decl.init) |init| {
            if (init.Assignment.rhs.* != .Constant) {
                ErrorReporter.report(.NonConstInitializer, decl.lineIndex, decl.name);
                return;
            }
            initialValue = .{ .Initial = .{ .int = init.Assignment.rhs.Constant } };
        }

        const attrs: Attrs = .{ .Static = .{ .initialValue = initialValue, .global = true } };
        symbols.put(decl.unique.?, .{ .type = .Int, .attrs = attrs }) catch allocError();
    } else { // automatic (local scope) storage class
        symbols.put(decl.unique.?, .{ .type = .Int, .attrs = .{ .Local = .{} } }) catch allocError();
        if (decl.init) |init| {
            typeCheckExpression(symbols, init);
        }
    }
}

fn typeCheckBlock(symbols: *SymbolTable, block: Block) void {
    for (block.items) |item| {
        switch (item) {
            .Declaration => |decl| typeCheckLocalDeclaration(symbols, decl),
            .Statement => |stmt| typeCheckStatement(symbols, stmt),
        }
    }
}

fn typeCheckStatement(symbols: *SymbolTable, stmt: Statement) void {
    switch (stmt) {
        .Compound => |compound| typeCheckBlock(symbols, compound),
        .Return => |ret| typeCheckExpression(symbols, ret.expr),
        .Expression => |expr| typeCheckExpression(symbols, expr),
        .If => |ifStmt| {
            typeCheckExpression(symbols, ifStmt.condition);
            typeCheckStatement(symbols, ifStmt.thenStmt.*);
            if (ifStmt.elseStmt) |els| typeCheckStatement(symbols, els.*);
        },
        .Label => |lbl| typeCheckStatement(symbols, lbl.body.*),
        .DoWhile => |doWhl| {
            typeCheckStatement(symbols, doWhl.body.*);
            typeCheckExpression(symbols, doWhl.cond);
        },
        .While => |whl| {
            typeCheckExpression(symbols, whl.cond);
            typeCheckStatement(symbols, whl.body.*);
        },
        .For => |f| {
            switch (f.init) {
                .Declaration => |decl| {
                    if (decl == .VarDecl and decl.VarDecl.storageClass != null) {
                        ErrorReporter.report(.ForLoopStorageClassDecl, decl.VarDecl.lineIndex, decl.VarDecl.name);
                        return;
                    }
                    typeCheckLocalDeclaration(symbols, decl);
                },
                .Expression => |expr| if (expr) |e| typeCheckExpression(symbols, e),
            }
            if (f.cond) |cond| typeCheckExpression(symbols, cond);
            if (f.post) |post| typeCheckExpression(symbols, post);
            typeCheckStatement(symbols, f.body.*);
        },
        .Switch => |swtch| {
            typeCheckExpression(symbols, swtch.cond);
            typeCheckStatement(symbols, swtch.body.*);
        },
        .Case => |case| {
            if (case.body) |body| typeCheckStatement(symbols, body.*);
        },
        .Break, .Continue, .Goto, .Null => {},
    }
}

fn typeCheckExpression(symbols: *SymbolTable, expr: Expression) void {
    switch (expr) {
        .Assignment => |assign| {
            typeCheckExpression(symbols, assign.lhs.*);
            typeCheckExpression(symbols, assign.rhs.*);
        },
        .Binary => |bin| {
            typeCheckExpression(symbols, bin.left.*);
            typeCheckExpression(symbols, bin.right.*);
        },
        .Var => |v| {
            const symbol = symbols.get(v.name) orelse {
                ErrorReporter.report(.UnresolvedSymbol, v.lineIndex, v.name);
                return;
            };
            if (symbol.type != .Int) {
                ErrorReporter.report(.VarUsedAsFunction, v.lineIndex, v.name);
                return;
            }
        },
        .Unary => |un| typeCheckExpression(symbols, un.operand.*),
        .Ternary => |tern| {
            typeCheckExpression(symbols, tern.condition.*);
            typeCheckExpression(symbols, tern.thenStmt.*);
            typeCheckExpression(symbols, tern.elseStmt.*);
        },
        .FunctionCall => |fcall| {
            const symbol = symbols.get(fcall.name).?; // semantics already ensures the function has been defined
            if (symbol.type != .FunType) {
                ErrorReporter.report(.CallOnNonFunction, fcall.lineIndex, null);
                return;
            }

            const funType = symbol.type.FunType;
            if (funType.nParams > fcall.args.len) {
                ErrorReporter.report(.TooFewArguments, fcall.lineIndex, null);
                return;
            }
            if (funType.nParams < fcall.args.len) {
                ErrorReporter.report(.TooManyArguments, fcall.lineIndex, null);
                return;
            }
            for (fcall.args) |arg| {
                typeCheckExpression(symbols, arg);
            }
        },
        .Constant => {},
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
