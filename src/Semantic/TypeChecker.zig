const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const log = std.log;
const process = std.process;

const Parser = @import("../Parser.zig");
const AST = Parser.AST;
const Block = Parser.Block;
const Declaration = Parser.Declaration;
const Expression = Parser.Expression;
const FunDecl = Parser.FunDecl;
const Statement = Parser.Statement;
const VarDecl = Parser.VarDecl;

const TypeChecker = @This();

const SymbolType = enum {
    Int,
};

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

const Entry = struct {
    type: Type,
    defined: ?bool = null,
};

const SymbolTable = StringHashMap(Entry);

pub fn run(allocator: Allocator, ast: *AST) void {
    var symbols: SymbolTable = .init(allocator);
    defer symbols.deinit();

    for (ast.tree.functions) |func| {
        typeCheckFunDecl(&symbols, func);
    }
}

fn typeCheckDeclaration(symbols: *SymbolTable, decl: Declaration) void {
    switch (decl) {
        .FunDecl => |funDecl| typeCheckFunDecl(symbols, funDecl),
        .VarDecl => |varDecl| typeCheckVarDecl(symbols, varDecl),
    }
}

fn typeCheckFunDecl(symbols: *SymbolTable, decl: FunDecl) void {
    const funType: FunType = .{ .type = .{}, .nParams = decl.params.len };
    var isDefined = false;

    if (symbols.get(decl.name)) |entry| {
        if (entry.type != .FunType or entry.type.FunType.nParams != funType.nParams) {
            // TODO: throw error instead
            log.err("Incompatible function declarations", .{});
            process.exit(1);
        }

        isDefined = entry.defined.?;
        if (isDefined and decl.body != null) {
            // TODO: throw error instead
            log.err("Function '{s}' defined more than once", .{decl.name});
            process.exit(1);
        }
    }
    symbols.put(decl.name, .{ .type = .{ .FunType = funType }, .defined = isDefined or decl.body != null }) catch @panic("OOM");

    if (decl.body) |body| {
        for (decl.params) |param| {
            symbols.put(param.unique.?, .{ .type = .Int }) catch @panic("OOM");
        }
        typeCheckBlock(symbols, body);
    }
}

fn typeCheckVarDecl(symbols: *SymbolTable, decl: VarDecl) void {
    symbols.put(decl.unique.?, .{ .type = .Int }) catch @panic("OOM");
    if (decl.init) |init| {
        typeCheckExpression(symbols, init);
    }
}

fn typeCheckBlock(symbols: *SymbolTable, block: Block) void {
    for (block.items) |item| {
        switch (item) {
            .Declaration => |decl| typeCheckDeclaration(symbols, decl),
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
                .Declaration => |decl| typeCheckDeclaration(symbols, decl),
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
            const symbol = symbols.get(v.name).?; // semantics already ensures the function has been defined
            if (symbol.type != .Int) {
                log.err("Function '{s}' cannot be used as a variable", .{v.name});
                process.exit(1);
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
                log.err("Called object type {any} is not a function or function pointer", .{fcall.name});
                process.exit(1);
            }

            const funType = symbol.type.FunType;
            if (funType.nParams > fcall.args.len) {
                log.err("Too few arguments in function call; expected {d}, got {d}", .{ funType.nParams, fcall.args.len });
                process.exit(1);
            }
            if (funType.nParams < fcall.args.len) {
                log.err("Too many arguments in function call; expected {d}, got {d}", .{ funType.nParams, fcall.args.len });
                process.exit(1);
            }
            for (fcall.args) |arg| {
                typeCheckExpression(symbols, arg);
            }
        },
        .Constant => {},
    }
}
