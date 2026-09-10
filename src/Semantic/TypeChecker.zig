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
    std.debug.print("Running type checker\n", .{});
    var symbols: SymbolTable = .init(allocator);
    defer symbols.deinit();

    for (ast.tree.functions) |func| {
        std.debug.print("{s}\n", .{func.name});
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
        if (entry.type != .FunType) {
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

        symbols.put(decl.name, .{ .type = .{ .FunType = funType }, .defined = isDefined or decl.body != null }) catch @panic("OOM");

        if (decl.body) |body| {
            for (decl.params) |param| {
                symbols.put(param.name, .{ .type = .Int }) catch @panic("OOM");
            }
            typeCheckBlock(symbols, body);
        }
    }
}

fn typeCheckVarDecl(symbols: *SymbolTable, decl: VarDecl) void {
    symbols.put(decl.name, .{ .type = .Int }) catch @panic("OOM");
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
        .Expression => |expr| typeCheckExpression(symbols, expr),
        else => {},
    }
}

fn typeCheckExpression(symbols: *SymbolTable, expr: Expression) void {
    switch (expr) {
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
        .Var => |v| {
            const symbol = symbols.get(v.name).?; // semantics already ensures the function has been defined
            if (symbol.type != .Int) {
                log.err("Function '{s}' cannot be used as a variable", .{v.name});
                process.exit(1);
            }
        },
        else => {},
    }
}
