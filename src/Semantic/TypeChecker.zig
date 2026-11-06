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
const Symbol = @import("Symbols.zig");

// Rather than pass around an entire Context, to keep things simple the error
// reporting will be handled by a global object. TODO: maybe revisit for a better
// solution
var ErrorReporter: *Error.Reporter = undefined;
var FunctionName: ?[]const u8 = null;

const TypeChecker = @This();

pub fn run(allocator: Allocator, symbols: *Symbol.Table, errorReporter: *Error.Reporter, tree: *AST) void {
    ErrorReporter = errorReporter;

    for (tree.declarations) |*decl| {
        switch (decl.*) {
            .FunDecl => |*funDecl| typeCheckFunDecl(allocator, symbols, funDecl),
            .VarDecl => |*varDecl| typeCheckFileScopeVarDecl(allocator, symbols, varDecl),
        }
    }
}

fn typeCheckLocalDeclaration(allocator: Allocator, symbols: *Symbol.Table, decl: *Declaration) void {
    switch (decl.*) {
        .FunDecl => |*funDecl| typeCheckFunDecl(allocator, symbols, funDecl),
        .VarDecl => |*varDecl| typeCheckLocalVarDecl(allocator, symbols, varDecl),
    }
}

fn typeCheckFunDecl(allocator: Allocator, symbols: *Symbol.Table, decl: *FunDecl) void {
    var isDefined: bool = decl.body != null;
    var isGlobal: bool = decl.storageClass != .Static;

    if (symbols.get(decl.name)) |entry| {
        if (entry.type != .FunType or // previous entry should be a function declaration, not variable
            entry.type.FunType.params.len != decl.params.len or // ...and have the same number of params
            !entry.type.FunType.ret.*.equals(decl.type.FunType.ret.*)) // ...and the same return type
        {
            ErrorReporter.report(.ConflictingFunctions, decl.lineIndex, decl.name);
            return;
        }

        for (decl.params, entry.type.FunType.params) |p, t| {
            if (!p.type.equals(t.*)) { // all params align on types
                ErrorReporter.report(.ConflictingFunctions, decl.lineIndex, decl.name);
                return;
            }
        }

        isDefined = entry.attrs.Fun.defined;
        if (isDefined and decl.body != null) { // check if this is a redeclaration
            ErrorReporter.report(.Redeclaration, decl.lineIndex, decl.name);
            return;
        }

        isGlobal = entry.attrs.Fun.global;
        if (isGlobal and decl.storageClass == .Static) { // ensure declarations agree on linkage
            ErrorReporter.report(.InvalidStaticDeclaration, decl.lineIndex, decl.name);
            return;
        }
    }

    const attrs: Symbol.Attrs = .{ .Fun = .{
        .defined = isDefined or decl.body != null,
        .global = isGlobal,
    } };
    symbols.put(decl.name, .{
        .type = decl.type,
        .attrs = attrs,
    }) catch allocError();

    if (decl.body) |*body| {
        for (decl.params) |param| {
            symbols.put(param.unique.?, .{ .type = param.type, .attrs = .Local }) catch allocError();
        }
        FunctionName = decl.name;
        typeCheckBlock(allocator, symbols, body);
        FunctionName = null;
    }
}

fn typeCheckFileScopeVarDecl(allocator: Allocator, symbols: *Symbol.Table, decl: *VarDecl) void {
    var initialValue: Symbol.Static.InitialValue = if (decl.storageClass == .Extern) .None else .Tentative;
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
                if (decl.init != null) {
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
    var attrs: Symbol.Attrs = .{ .Static = .{ .initialValue = initialValue, .global = isGlobal } };
    symbols.put(decl.name, .{ .type = decl.type, .attrs = attrs }) catch allocError();

    // Now that we've added an entry to the symbol table, type check init (if it exists) and update
    // the entry if need be
    if (decl.init) |*init| {
        if (init.Assignment.rhs.* == .Constant) {
            _ = typeCheckExpression(allocator, symbols, init);
            initialValue = .{ .Initial = init.Assignment.rhs.Constant };
            attrs = .{ .Static = .{ .initialValue = initialValue, .global = isGlobal } };

            symbols.put(decl.name, .{ .type = decl.type, .attrs = attrs }) catch allocError();
        } else {
            // TODO: revisit this when SemanticError becomes an error class
            // Report an error, but continue as if there's no initialization
            ErrorReporter.report(.NonConstInitializer, decl.lineIndex, decl.name);
        }
    }
}

fn typeCheckLocalVarDecl(allocator: Allocator, symbols: *Symbol.Table, decl: *VarDecl) void {
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
            const attrs: Symbol.Attrs = .{ .Static = .{ .initialValue = .None, .global = true } };
            symbols.put(decl.name, .{ .type = decl.type, .attrs = attrs }) catch allocError();
        }
    } else if (decl.storageClass == .Static) {
        var initialValue: Symbol.Static.InitialValue = switch (decl.type) {
            .Double => .{ .Initial = .{ .double = 0 } },
            .Int => .{ .Initial = .{ .int = 0 } },
            .Long => .{ .Initial = .{ .long = 0 } },
            .UInt => .{ .Initial = .{ .uint = 0 } },
            .ULong => .{ .Initial = .{ .ulong = 0 } },
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

        const attrs: Symbol.Attrs = .{ .Static = .{ .initialValue = initialValue, .global = true } };
        symbols.put(decl.unique.?, .{ .type = decl.type, .attrs = attrs }) catch allocError();
    } else { // automatic (local scope) storage class
        symbols.put(decl.unique.?, .{ .type = decl.type, .attrs = .Local }) catch allocError();
        if (decl.init) |*init| {
            _ = typeCheckExpression(allocator, symbols, init);
        }
    }
}

fn typeCheckBlock(allocator: Allocator, symbols: *Symbol.Table, block: *Block) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Declaration => |*decl| typeCheckLocalDeclaration(allocator, symbols, decl),
            .Statement => |*stmt| typeCheckStatement(allocator, symbols, stmt),
        }
    }
}

fn typeCheckStatement(allocator: Allocator, symbols: *Symbol.Table, stmt: *Statement) void {
    switch (stmt.*) {
        .Compound => |*compound| typeCheckBlock(allocator, symbols, compound),
        .Return => |*ret| {
            _ = typeCheckExpression(allocator, symbols, &ret.expr);

            const symbol = symbols.get(FunctionName.?) orelse unreachable;
            ret.expr = Cast.to(allocator, &ret.expr, symbol.type.FunType.ret.*);
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
            const condType = typeCheckExpression(allocator, symbols, &swtch.cond);
            if (condType == .Double) {
                ErrorReporter.report(.NonIntegerStatement, swtch.lineIndex, "double");
                return;
            }
            typeCheckStatement(allocator, symbols, swtch.body);
        },
        .Case => |*case| {
            if (case.cond) |*cond| {
                // No current support 'const' expressions, so only expect null ('default') or literal constants
                if (cond.* != .Constant) {
                    ErrorReporter.report(.NonConstCase, case.lineIndex, null);
                    return;
                }

                const condType = typeCheckExpression(allocator, symbols, cond);
                if (condType == .Double) {
                    ErrorReporter.report(.NonIntegerStatement, case.lineIndex, "double");
                    return;
                }
                const parentType = case.parent.?.cond.getType();
                case.cond = Cast.to(allocator, cond, parentType);
            }

            case.registerToParentSwitch(allocator) catch {
                ErrorReporter.report(.CaseDuplicate, case.lineIndex, null);
            };

            if (case.body) |body| typeCheckStatement(allocator, symbols, body);
        },
        .Break, .Continue, .Goto, .Null => {},
    }
}

fn typeCheckExpression(allocator: Allocator, symbols: *Symbol.Table, expr: *Expression) Type {
    switch (expr.*) {
        .Assignment => |*assign| {
            const lType = typeCheckExpression(allocator, symbols, assign.lhs);
            _ = typeCheckExpression(allocator, symbols, assign.rhs);

            assign.type = lType;
            assign.rhs.* = Cast.to(allocator, assign.rhs, lType);

            return assign.type.?;
        },
        .Binary => |*bin| {
            const lType = typeCheckExpression(allocator, symbols, bin.left);
            const rType = typeCheckExpression(allocator, symbols, bin.right);

            if (lType == .Double or rType == .Double) {
                switch (bin.operator) {
                    .AndB, .Mod, .OrB, .ShiftL, .ShiftR, .Xor => ErrorReporter.report(.BinaryDoubleOperand, bin.lineIndex, null),
                    else => {},
                }
            }

            const commonType = switch (bin.operator) {
                .ShiftL, .ShiftR => lType, // bit-shifts are a special case that always assmue the type of the base number
                else => Type.getCommon(lType, rType),
            };

            bin.type = commonType;
            bin.left.* = Cast.to(allocator, bin.left, commonType);
            bin.right.* = Cast.to(allocator, bin.right, commonType);

            if (bin.operator == .ShiftL) {
                bin.operator = if (commonType.signed()) .SAL else .SHL;
            } else if (bin.operator == .ShiftR) {
                bin.operator = if (commonType.signed()) .SAR else .SHR;
            }

            return bin.type.?;
        },
        .Cast => |*cast| {
            _ = typeCheckExpression(allocator, symbols, cast.exp);
            return cast.target.type.?;
        },
        .Constant => return switch (expr.Constant) {
            .double => .Double,
            .int => .Int,
            .long => .Long,
            .uint => .UInt,
            .ulong => .ULong,
        },
        .FunctionCall => |*fcall| {
            const symbol = symbols.get(fcall.name).?; // semantics already ensures the function has been defined
            if (symbol.type != .FunType) {
                ErrorReporter.report(.CallOnNonFunction, fcall.lineIndex, null);
                fcall.type = symbol.type;
                return fcall.type.?;
            }
            const funType = symbol.type.FunType;
            fcall.type = funType.ret.*;

            if (funType.params.len > fcall.args.len) {
                ErrorReporter.report(.TooFewArguments, fcall.lineIndex, null);
            } else if (funType.params.len < fcall.args.len) {
                ErrorReporter.report(.TooManyArguments, fcall.lineIndex, null);
            } else {
                for (fcall.args, funType.params) |*arg, param| {
                    _ = typeCheckExpression(allocator, symbols, arg);
                    arg.* = Cast.to(allocator, arg, param.*);
                }
            }

            return fcall.type.?;
        },
        .Ternary => |*tern| {
            const ifType = typeCheckExpression(allocator, symbols, tern.condition);
            const thenType = typeCheckExpression(allocator, symbols, tern.thenExpr);
            const elseType = typeCheckExpression(allocator, symbols, tern.elseExpr);

            var commonType = Type.getCommon(ifType, thenType);
            commonType = Type.getCommon(commonType, elseType);

            tern.type = commonType;
            tern.condition.* = Cast.to(allocator, tern.condition, commonType);
            tern.thenExpr.* = Cast.to(allocator, tern.thenExpr, commonType);
            tern.elseExpr.* = Cast.to(allocator, tern.elseExpr, commonType);

            return tern.type.?;
        },
        .Unary => |*un| {
            const operandType = typeCheckExpression(allocator, symbols, un.operand);
            if (operandType == .Double and un.operator == .Complement) {
                ErrorReporter.report(.UnaryDoubleOperand, un.lineIndex, null);
            }

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
                v.type = symbol.type.FunType.ret.*;
                return v.type.?;
            }

            v.type = symbol.type;
            return v.type.?;
        },
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
