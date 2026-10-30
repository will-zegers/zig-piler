const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const process = std.process;
const mem = std.mem;

const Parser = @import("../Parser.zig");
const AST = Parser.AST;
const Block = Parser.Block;
const Cast = Parser.Cast;
const Declaration = Parser.Declaration;
const Expression = Parser.Expression;
const FunDecl = Parser.FunDecl;
const Statement = Parser.Statement;
const Type = Parser.Type;
const VarDecl = Parser.VarDecl;

const Error = @import("Error.zig");
const Symbols = @import("Symbols.zig");

// Rather than pass around an entire Context, to keep things simple the error
// reporting will be handled by a global object. TODO: maybe revisit for a better
// solution
var ErrorReporter: *Error.Reporter = undefined;
var FunctionName: ?[]const u8 = null;

const TypeChecker = @This();

pub fn run(allocator: Allocator, symbols: *Symbols.Table, errorReporter: *Error.Reporter, tree: *AST) void {
    ErrorReporter = errorReporter;

    for (tree.declarations) |*decl| {
        switch (decl.*) {
            .FunDecl => |*funDecl| typeCheckFunDecl(allocator, symbols, funDecl),
            .VarDecl => |*varDecl| typeCheckFileScopeVarDecl(symbols, varDecl),
        }
    }
}

fn typeCheckLocalDeclaration(allocator: Allocator, symbols: *Symbols.Table, decl: *Declaration) void {
    switch (decl.*) {
        .FunDecl => |*funDecl| typeCheckFunDecl(allocator, symbols, funDecl),
        .VarDecl => |*varDecl| typeCheckLocalVarDecl(allocator, symbols, varDecl),
    }
}

fn typeCheckFunDecl(allocator: Allocator, symbols: *Symbols.Table, decl: *FunDecl) void {
    var isDefined: bool = decl.body != null;
    var isGlobal: bool = decl.storageClass != .Static;

    if (symbols.get(decl.name)) |entry| {
        if (entry.type != .FunType or entry.type.FunType.params.len != decl.params.len) {
            ErrorReporter.report(.ConflictingFunctions, decl.lineIndex, decl.name);
            return;
        }

        for (decl.params, entry.type.FunType.params) |p, t| {
            if (!p.type.equals(t.*)) {
                ErrorReporter.report(.ConflictingFunctions, decl.lineIndex, decl.name);
                return;
            }
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

    const attrs: Symbols.Attrs = .{ .Fun = .{
        .defined = isDefined or decl.body != null,
        .global = isGlobal,
    } };
    symbols.put(decl.name, .{
        .type = decl.type,
        .attrs = attrs,
    }) catch allocError();

    for (decl.params) |param| {
        if (param.storageClass != null) {
            ErrorReporter.report(.InvalidStorageClass, param.lineIndex, param.name);
            return;
        }

        if (param.init != null) {
            ErrorReporter.report(.DefaultArgument, param.lineIndex, param.name);
            return;
        }
    }

    if (decl.body) |*body| {
        for (decl.params) |param| {
            symbols.put(param.unique.?, .{ .type = param.type, .attrs = .Local }) catch allocError();
        }
        FunctionName = decl.name;
        typeCheckBlock(allocator, symbols, body);
        FunctionName = null;
    }
}

fn typeCheckFileScopeVarDecl(symbols: *Symbols.Table, decl: *VarDecl) void {
    var initialValue: Symbols.Static.InitialValue = undefined;
    if (decl.init) |init| {
        // TODO: extend initialize to use constant binary and unary expressions
        if (init.Assignment.rhs.* == .Constant) {
            initialValue = .{ .Initial = init.Assignment.rhs.Constant };
        } else {
            // Report an error, but continue as if there's no initialization
            ErrorReporter.report(.NonConstInitializer, decl.lineIndex, decl.name);
        }
    } else { // no initializer
        if (decl.storageClass == .Extern) {
            initialValue = .None;
        } else {
            initialValue = .Tentative;
        }
    }

    var isGlobal = decl.storageClass != .Static;
    if (symbols.get(decl.name)) |entry| {
        if (!entry.type.equals(decl.type)) {
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

        switch (entry.attrs.Static.initialValue) {
            .Initial => |init| { // ensure no redefinitions of global variables
                if (initialValue == .Initial) {
                    ErrorReporter.report(.VariableRedefinition, decl.lineIndex, decl.name);
                    return;
                }
                initialValue = .{ .Initial = init };
            },
            .Tentative => {
                if (initialValue != .Initial) {
                    initialValue = .Tentative;
                }
            },
            .None => {},
        }
    }

    const attrs: Symbols.Attrs = .{ .Static = .{ .initialValue = initialValue, .global = isGlobal } };
    symbols.put(decl.name, .{ .type = decl.type, .attrs = attrs }) catch allocError();
}

fn typeCheckLocalVarDecl(allocator: Allocator, symbols: *Symbols.Table, decl: *VarDecl) void {
    if (decl.storageClass == .Extern) {
        if (decl.init) |_| {
            ErrorReporter.report(.LocalExternDefined, decl.lineIndex, decl.name);
        }
        if (symbols.get(decl.name)) |entry| {
            if (!entry.type.equals(decl.type)) {
                ErrorReporter.report(.Redeclaration, decl.lineIndex, decl.name);
                return;
            }
        } else {
            const attrs: Symbols.Attrs = .{ .Static = .{ .initialValue = .None, .global = true } };
            symbols.put(decl.name, .{ .type = decl.type, .attrs = attrs }) catch allocError();
        }
    } else if (decl.storageClass == .Static) {
        var initialValue: Symbols.Static.InitialValue = switch (decl.type) {
            .Int => .{ .Initial = .{ .int = 0 } },
            .Long => .{ .Initial = .{ .long = 0 } },
            .FunType => unreachable,
        };
        if (decl.init) |init| {
            if (init.Assignment.rhs.* == .Constant) {
                initialValue = .{ .Initial = init.Assignment.rhs.Constant };
            } else {
                // Report an error, but continue as if there's no initialization
                ErrorReporter.report(.NonConstInitializer, decl.lineIndex, decl.name);
            }
        }

        const attrs: Symbols.Attrs = .{ .Static = .{ .initialValue = initialValue, .global = true } };
        symbols.put(decl.unique.?, .{ .type = decl.type, .attrs = attrs }) catch allocError();
    } else { // automatic (local scope) storage class
        symbols.put(decl.unique.?, .{ .type = decl.type, .attrs = .Local }) catch allocError();
        if (decl.init) |*init| {
            _ = typeCheckExpression(allocator, symbols, init);
        }
    }
}

fn typeCheckBlock(allocator: Allocator, symbols: *Symbols.Table, block: *Block) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Declaration => |*decl| typeCheckLocalDeclaration(allocator, symbols, decl),
            .Statement => |*stmt| typeCheckStatement(allocator, symbols, stmt),
        }
    }
}

fn typeCheckStatement(allocator: Allocator, symbols: *Symbols.Table, stmt: *Statement) void {
    switch (stmt.*) {
        .Compound => |*compound| typeCheckBlock(allocator, symbols, compound),
        .Return => |*ret| {
            _ = typeCheckExpression(allocator, symbols, &ret.expr);

            const symbol = symbols.get(FunctionName.?) orelse unreachable;
            ret.expr = castTo(allocator, &ret.expr, symbol.type.FunType.ret.*);
        },
        .Expression => |*expr| _ = typeCheckExpression(allocator, symbols, expr),
        .If => |*ifStmt| {
            _ = typeCheckExpression(allocator, symbols, &ifStmt.condition);
            typeCheckStatement(allocator, symbols, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |els| typeCheckStatement(allocator, symbols, els);
        },
        .Label => |*lbl| typeCheckStatement(allocator, symbols, lbl.body),
        .DoWhile => |*doWhl| {
            typeCheckStatement(allocator, symbols, doWhl.body);
            _ = typeCheckExpression(allocator, symbols, &doWhl.cond);
        },
        .While => |*whl| {
            _ = typeCheckExpression(allocator, symbols, &whl.cond);
            typeCheckStatement(allocator, symbols, whl.body);
        },
        .For => |*f| {
            switch (f.init) {
                .Declaration => |*decl| {
                    if (decl.* == .FunDecl) {
                        ErrorReporter.report(.ForLoopFunctionDecl, decl.FunDecl.lineIndex, decl.FunDecl.name);
                        return;
                    }
                    if (decl.* == .VarDecl and decl.VarDecl.storageClass != null) {
                        ErrorReporter.report(.ForLoopStorageClassDecl, decl.VarDecl.lineIndex, decl.VarDecl.name);
                        return;
                    }
                    typeCheckLocalDeclaration(allocator, symbols, decl);
                },
                .Expression => |*expr| _ = if (expr.*) |*e| typeCheckExpression(allocator, symbols, e) else null,
            }
            if (f.cond) |*cond| _ = typeCheckExpression(allocator, symbols, cond);
            if (f.post) |*post| _ = typeCheckExpression(allocator, symbols, post);
            typeCheckStatement(allocator, symbols, f.body);
        },
        .Switch => |*swtch| {
            _ = typeCheckExpression(allocator, symbols, &swtch.cond);
            typeCheckStatement(allocator, symbols, swtch.body);
        },
        .Case => |*case| {
            if (case.cond) |*cond| {
                _ = typeCheckExpression(allocator, symbols, cond);
                const parentType = case.parent.?.cond.getType();
                case.cond = castTo(allocator, cond, parentType);
            }

            case.registerToParentSwitch() catch {
                ErrorReporter.report(.CaseDuplicate, case.lineIndex, null);
            };

            if (case.body) |body| typeCheckStatement(allocator, symbols, body);
        },
        .Break, .Continue, .Goto, .Null => {},
    }
}

// TODO: use constCast to make this the only function that needs mutable
fn typeCheckExpression(allocator: Allocator, symbols: *Symbols.Table, expr: *Expression) Type {
    switch (expr.*) {
        .Assignment => |*assign| {
            const lType = typeCheckExpression(allocator, symbols, assign.lhs);
            _ = typeCheckExpression(allocator, symbols, assign.rhs);

            assign.type = lType;
            assign.rhs.* = castTo(allocator, assign.rhs, lType);

            return assign.type.?;
        },
        .Binary => |*bin| {
            const lType = typeCheckExpression(allocator, symbols, bin.left);
            const rType = typeCheckExpression(allocator, symbols, bin.right);
            const commonType = getCommonType(lType, rType);

            bin.type = commonType;
            bin.left.* = castTo(allocator, bin.left, lType);
            bin.right.* = castTo(allocator, bin.right, lType);

            return bin.type.?;
        },
        .Cast => |*cast| {
            if (cast.target.storageClass != null) {
                ErrorReporter.report(.InvalidStorageClass, cast.lineIndex, null);
            }

            _ = typeCheckExpression(allocator, symbols, cast.exp);
            return cast.target.type.?;
        },
        .Constant => return switch (expr.Constant) {
            .int => .Int,
            .long => .Long,
        },
        .FunctionCall => |*fcall| {
            const symbol = symbols.get(fcall.name).?; // semantics already ensures the function has been defined
            if (symbol.type != .FunType) {
                ErrorReporter.report(.CallOnNonFunction, fcall.lineIndex, null);
                fcall.type = symbol.type;
                return fcall.type.?;
            }
            const funType = symbol.type.FunType;
            if (funType.params.len > fcall.args.len) {
                ErrorReporter.report(.TooFewArguments, fcall.lineIndex, null);
            }
            if (funType.params.len < fcall.args.len) {
                ErrorReporter.report(.TooManyArguments, fcall.lineIndex, null);
            }

            fcall.type = symbol.type.FunType.ret.*;
            for (fcall.args) |*arg| {
                _ = typeCheckExpression(allocator, symbols, arg);
            }

            return fcall.type.?;
        },
        .Ternary => |*tern| {
            // TODO: Fix Ternary names (thenStmt -> thenExpr)
            const ifType = typeCheckExpression(allocator, symbols, tern.condition);
            const thenType = typeCheckExpression(allocator, symbols, tern.thenStmt);
            const elseType = typeCheckExpression(allocator, symbols, tern.elseStmt);

            var commonType = getCommonType(ifType, thenType);
            commonType = getCommonType(commonType, elseType);

            tern.type = commonType;
            tern.condition.* = castTo(allocator, tern.condition, commonType);
            tern.thenStmt.* = castTo(allocator, tern.thenStmt, commonType);
            tern.elseStmt.* = castTo(allocator, tern.elseStmt, commonType);

            return tern.type.?;
        },
        .Unary => |*un| {
            const operandType = typeCheckExpression(allocator, symbols, un.operand);
            // std.process.exit(1);
            un.type = switch (un.operator) {
                .Not => .Int,
                else => operandType,
            };

            return un.type.?;
        },
        .Var => |*v| {
            const symbol = symbols.get(v.name) orelse unreachable;
            if (symbol.type == .FunType) {
                ErrorReporter.report(.FunctionUsedAsVariable, v.lineIndex, v.name);
            }

            v.type = symbol.type;
            return v.type.?;
        },
    }
}

fn castTo(allocator: Allocator, exp: *const Expression, toType: Type) Expression {
    const newExp: Expression = switch (exp.getType()) {
        .Int => switch (toType) {
            .Int => exp.*,
            else => .{ .Cast = .to(allocator, exp, toType) },
        },
        .Long => switch (toType) {
            .Long => exp.*,
            else => .{ .Cast = .to(allocator, exp, toType) },
        },
        .FunType => exp.*,
    };
    return newExp;
}

fn getCommonType(type1: Type, type2: Type) Type {
    return switch (type1) {
        .Long => .Long,
        else => switch (type2) {
            .Int => .Int,
            else => type2,
        },
    };
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
