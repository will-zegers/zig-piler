const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const log = std.log;
const process = std.process;

const Parser = @import("Parser.zig");
const Semantic = @import("Semantic.zig");
const Symbol = @import("Semantic/Symbols.zig");
const instr = @import("TAC/instruction.zig");

pub const Binary = instr.Binary;
pub const Copy = instr.Copy;
pub const Constant = instr.Constant;
pub const FunCall = instr.FunCall;
pub const Instruction = instr.Instruction;
pub const Jump = instr.Jump;
pub const Label = instr.Label;
pub const Return = instr.Return;
pub const SignExtend = instr.SignExtend;
pub const Truncate = instr.Truncate;
pub const Unary = instr.Unary;
const Val = instr.Val;

pub const TAC = @This();

const Instructions = ArrayList(Instruction);
var SymbolTable: Symbol.Table = undefined;

pub const Program = struct {
    arena: ArenaAllocator,
    topLevel: []TopLevel,
    symbols: Symbol.Table,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }
};

var counter: usize = 0;
const Context = struct {
    name: []const u8,
    counter: usize = 0,
};

pub const Function = struct {
    name: []const u8,
    global: bool,
    params: []Parser.VarDecl,
    body: []Instruction,
};

pub const StaticVariable = struct {
    type: Parser.Type,
    identifier: []const u8,
    global: bool,
    init: Symbol.Static.InitialValue,
};

const TopLevelTag = enum { Function, StaticVariable };
const TopLevel = union(TopLevelTag) {
    Function: Function,
    StaticVariable: StaticVariable,
};

pub fn emit(allocator: Allocator, tree: Semantic.AST) Program {
    // This will be doing a lot of miscellaneous allocations for tags and labels,
    // so just handle clean-up with an arena instead of meticulous bookkeeping
    var arena: ArenaAllocator = .init(allocator);
    const arenaAllocator = arena.allocator();

    SymbolTable = tree.symbols;

    var topLevelList: ArrayList(TopLevel) = .empty;
    for (tree.tree.declarations) |decl| {
        switch (decl) {
            .FunDecl => |funDecl| {
                if (funDecl.body == null) continue; // discard function declaration without bodies

                const func = emitFunDecl(arenaAllocator, funDecl);
                topLevelList.append(arenaAllocator, .{ .Function = func }) catch allocError();
            },
            .VarDecl => {},
        }
    }
    const symbolDefs = emitStorageClassSymbols(arenaAllocator);
    topLevelList.appendSlice(arenaAllocator, symbolDefs) catch allocError();

    const topLevel = topLevelList.toOwnedSlice(arenaAllocator) catch allocError();
    return .{ .arena = arena, .topLevel = topLevel, .symbols = tree.symbols };
}

fn emitDeclaration(allocator: Allocator, context: *Context, body: *Instructions, decl: Parser.Declaration) !void {
    switch (decl) {
        .VarDecl => |varDecl| {
            if (varDecl.storageClass != null) return;

            if (varDecl.init) |initExpr| {
                _ = emitExpression(allocator, context, body, initExpr);
            }
        },
        .FunDecl => |funDecl| _ = emitFunDecl(allocator, funDecl),
    }
}

fn emitFunDecl(allocator: Allocator, funDecl: Parser.FunDecl) Function {
    var instructions: Instructions = .empty;

    if (funDecl.body) |body| {
        var context: Context = .{ .name = funDecl.name, .counter = 0 };
        emitBlock(allocator, &context, &instructions, body) catch allocError();
    }
    instructions.append(allocator, .{ .Return = .{ .val = .{ .Constant = .{ .int = 0 } } } }) catch allocError();

    const body = instructions.toOwnedSlice(allocator) catch allocError();
    const entry = SymbolTable.get(funDecl.name) orelse {
        // Should never hit this if semantic analysis is doing its job
        log.err("Symbol '{s}' not found", .{funDecl.name});
        process.exit(1);
    };

    return .{ .name = funDecl.name, .global = entry.attrs.Fun.global, .params = funDecl.params, .body = body };
}

fn emitBlock(allocator: Allocator, context: *Context, instructions: *Instructions, block: Parser.Block) !void {
    for (block.items) |item| {
        switch (item) {
            .Declaration => |decl| try emitDeclaration(allocator, context, instructions, decl),
            .Statement => |stmt| try emitStatement(allocator, context, instructions, stmt),
        }
    }
}

fn emitStatement(allocator: Allocator, context: *Context, instructions: *Instructions, stmt: Parser.Statement) !void {
    switch (stmt) {
        .Compound => |compound| {
            for (compound.items) |item| {
                switch (item) {
                    .Declaration => |d| try emitDeclaration(allocator, context, instructions, d),
                    .Statement => |s| try emitStatement(allocator, context, instructions, s),
                }
            }
        },
        .Return => |ret| {
            const val = emitExpression(allocator, context, instructions, ret.expr);
            try instructions.append(allocator, .{ .Return = .{ .val = val } });
        },
        .Expression => |expr| _ = emitExpression(allocator, context, instructions, expr),
        .Null => {},
        .If => |ifStmt| {
            const elseLabel = try newLabel(allocator, context.name, "else");
            const endLabel = try newLabel(allocator, context.name, "end");

            const c = emitExpression(allocator, context, instructions, ifStmt.condition);
            try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = c, .target = elseLabel } });

            _ = try emitStatement(allocator, context, instructions, ifStmt.thenStmt.*);
            try instructions.append(allocator, .{ .Jump = .{ .target = endLabel } });

            try instructions.append(allocator, .{ .Label = .{ .identifier = elseLabel } });
            if (ifStmt.elseStmt) |elseStmt| _ = try emitStatement(allocator, context, instructions, elseStmt.*);

            try instructions.append(allocator, .{ .Label = .{ .identifier = endLabel } });
        },
        .Label => |lbl| {
            try instructions.append(allocator, .{ .Label = .{ .identifier = lbl.tag.? } });
            _ = try emitStatement(allocator, context, instructions, lbl.body.*);
        },
        .Goto => |goto| try instructions.append(allocator, .{ .Jump = .{ .target = goto.target } }),
        .Break => |b| {
            const breakLabel = try allocator.print("{s}.break", .{b.tag.?});

            try instructions.append(allocator, .{ .Jump = .{ .target = breakLabel } });
        },
        .Continue => |c| {
            const continueLabel = try allocator.print("{s}.continue", .{c.tag.?});

            try instructions.append(allocator, .{ .Jump = .{ .target = continueLabel } });
        },
        .DoWhile => |d| {
            const startLabel = try allocator.print("{s}.start", .{d.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = startLabel } });

            try emitStatement(allocator, context, instructions, d.body.*);

            const continueLabel = try allocator.print("{s}.continue", .{d.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = continueLabel } });

            const e = emitExpression(allocator, context, instructions, d.cond);
            try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = e, .target = startLabel } });

            const breakLabel = try allocator.print("{s}.break", .{d.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = breakLabel } });
        },
        .While => |w| {
            const continueLabel = try allocator.print("{s}.continue", .{w.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = continueLabel } });

            const e = emitExpression(allocator, context, instructions, w.cond);

            const breakLabel = try allocator.print("{s}.break", .{w.tag.?});
            try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = e, .target = breakLabel } });

            try emitStatement(allocator, context, instructions, w.body.*);
            try instructions.append(allocator, .{ .Jump = .{ .target = continueLabel } });
            try instructions.append(allocator, .{ .Label = .{ .identifier = breakLabel } });
        },
        .For => |f| {
            switch (f.init) {
                .Declaration => try emitDeclaration(allocator, context, instructions, f.init.Declaration),
                .Expression => |expr| if (expr) |exprInit| {
                    _ = emitExpression(allocator, context, instructions, exprInit);
                },
            }

            const startLabel = try allocator.print("{s}.start", .{f.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = startLabel } });

            const breakLabel = try allocator.print("{s}.break", .{f.tag.?});

            if (f.cond) |cond| {
                const e = emitExpression(allocator, context, instructions, cond);
                try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = e, .target = breakLabel } });
            } else {
                try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = .{ .Constant = .{ .int = 1 } }, .target = breakLabel } });
            }

            try emitStatement(allocator, context, instructions, f.body.*);

            const continueLabel = try allocator.print("{s}.continue", .{f.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = continueLabel } });

            if (f.post) |post| _ = emitExpression(allocator, context, instructions, post);

            try instructions.append(allocator, .{ .Jump = .{ .target = startLabel } });
            try instructions.append(allocator, .{ .Label = .{ .identifier = breakLabel } });
        },
        .Switch => |sw| {
            const switchBreak = try allocator.print("{s}.break", .{sw.tag.?});

            const c = emitExpression(allocator, context, instructions, sw.cond);
            const tag = try newVariable(allocator, context.name, sw.cond.getType());
            const dst: Val = .{ .Var = tag };

            for (sw.cases.items) |case| {
                if (case.cond) |cond| { // ignore 'default' for now
                    const e = emitExpression(allocator, context, instructions, cond);
                    try instructions.append(allocator, .{ .Binary = .{ .operator = .Eq, .src1 = c, .src2 = e, .dst = dst } });
                    try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = dst, .target = &case.tag } });
                }
            }
            // jump to the default statement if one exists, else to the end of the switch statement
            if (sw.defaultTag) |defaultTag| {
                try instructions.append(allocator, .{ .Jump = .{ .target = defaultTag } });
            } else {
                try instructions.append(allocator, .{ .Jump = .{ .target = switchBreak } });
            }

            try emitStatement(allocator, context, instructions, sw.body.*);

            try instructions.append(allocator, .{ .Label = .{ .identifier = switchBreak } });
        },
        .Case => |case| {
            try instructions.append(allocator, .{ .Label = .{ .identifier = &case.tag } });
            if (case.body) |body| try emitStatement(allocator, context, instructions, body.*);
        },
    }
}

fn emitExpression(allocator: Allocator, context: *Context, instructions: *Instructions, expr: Parser.Expression) Val {
    // We need to catch any allocation errors here to prevent a dependency loop on error set of function
    return switch (expr) {
        .Assignment => |assign| emitAssignment(allocator, context, instructions, assign) catch allocError(),
        .Binary => |binary| emitBinary(allocator, context, instructions, binary) catch allocError(),
        .Cast => |cast| emitCast(allocator, context, instructions, cast) catch allocError(),
        .Constant => .{ .Constant = expr.Constant },
        .FunctionCall => |funCall| emitFunCall(allocator, context, instructions, funCall) catch allocError(),
        .Ternary => |ternary| emitTernary(allocator, context, instructions, ternary) catch allocError(),
        .Unary => |unary| emitUnary(allocator, context, instructions, unary) catch allocError(),
        .Var => .{ .Var = expr.Var.name },
    };
}

fn emitAssignment(allocator: Allocator, context: *Context, instructions: *Instructions, assign: Parser.Assignment) !Val {
    const result = emitExpression(allocator, context, instructions, assign.rhs.*);
    const dst = emitExpression(allocator, context, instructions, assign.lhs.*);

    // If this is a compound assignment, we need to emit a binary instruction.
    // Otherwise, for simple assignments we just emit a copy.
    try instructions.append(allocator, if (assign.operator) |op|
        .{ .Binary = .{ .operator = op, .src1 = dst, .src2 = result, .dst = dst } }
    else
        .{ .Copy = .{ .src = result, .dst = dst } });

    return dst;
}

fn emitBinary(allocator: Allocator, context: *Context, instructions: *Instructions, binary: Parser.Binary) !Val {
    switch (binary.operator) {
        .AndL => {
            const falseLabel = try newLabel(allocator, context.name, "andFalse");
            const endLabel = try newLabel(allocator, context.name, "andEnd");

            const v1 = emitExpression(allocator, context, instructions, binary.left.*);
            try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = v1, .target = falseLabel } });

            const v2 = emitExpression(allocator, context, instructions, binary.right.*);
            try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = v2, .target = falseLabel } });

            const tag = try newVariable(allocator, context.name, .Int);
            const dst: Val = .{ .Var = tag };
            try instructions.appendSlice(allocator, &.{
                .{ .Copy = .{ .src = .{ .Constant = .{ .int = 1 } }, .dst = dst } },
                .{ .Jump = .{ .target = endLabel } },
                .{ .Label = .{ .identifier = falseLabel } },
                .{ .Copy = .{ .src = .{ .Constant = .{ .int = 0 } }, .dst = dst } },
                .{ .Label = .{ .identifier = endLabel } },
            });
            return dst;
        },
        .OrL => {
            const trueLabel = try newLabel(allocator, context.name, "orTrue");
            const endLabel = try newLabel(allocator, context.name, "orEnd");

            const v1 = emitExpression(allocator, context, instructions, binary.left.*);
            try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = v1, .target = trueLabel } });

            const v2 = emitExpression(allocator, context, instructions, binary.right.*);
            try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = v2, .target = trueLabel } });

            const tag = try newVariable(allocator, context.name, .Int);
            const dst: Val = .{ .Var = tag };
            try instructions.appendSlice(allocator, &.{
                .{ .Copy = .{ .src = .{ .Constant = .{ .int = 0 } }, .dst = dst } },
                .{ .Jump = .{ .target = endLabel } },
                .{ .Label = .{ .identifier = trueLabel } },
                .{ .Copy = .{ .src = .{ .Constant = .{ .int = 1 } }, .dst = dst } },
                .{ .Label = .{ .identifier = endLabel } },
            });
            return dst;
        },
        else => {
            const src1 = emitExpression(allocator, context, instructions, binary.left.*);
            const src2 = emitExpression(allocator, context, instructions, binary.right.*);
            const tag = try newVariable(allocator, context.name, binary.type.?);
            const dst: Val = .{ .Var = tag };
            try instructions.append(allocator, .{ .Binary = .{ .operator = binary.operator, .src1 = src1, .src2 = src2, .dst = dst } });
            return dst;
        },
    }
}

fn emitCast(allocator: Allocator, context: *Context, instructions: *Instructions, cast: Parser.Cast) !Val {
    const expr = emitExpression(allocator, context, instructions, cast.exp.*);

    const to = cast.target.type.?;
    const exprType = cast.exp.getType();
    if (exprType.equals(to)) return expr;

    const tag = try newVariable(allocator, context.name, to);
    const dst: Val = .{ .Var = tag };

    switch (to) {
        .Int => try instructions.append(allocator, .{ .Truncate = .{ .src = expr, .dst = dst } }),
        .Long => try instructions.append(allocator, .{ .SignExtend = .{ .src = expr, .dst = dst } }),
        .FunType => unreachable,
    }

    return dst;
}

fn emitFunCall(allocator: Allocator, context: *Context, instructions: *Instructions, funCall: Parser.FunctionCall) !Val {
    const tag = try newVariable(allocator, context.name, funCall.type.?);
    const dst: Val = .{ .Var = tag };

    var args: ArrayList(Val) = try .initCapacity(allocator, funCall.args.len);
    for (funCall.args) |arg| {
        try args.append(allocator, emitExpression(allocator, context, instructions, arg));
    }
    try instructions.append(allocator, .{ .FunCall = .{ .name = funCall.name, .args = try args.toOwnedSlice(allocator), .dst = dst } });

    return dst;
}

fn emitTernary(allocator: Allocator, context: *Context, instructions: *Instructions, tern: Parser.Ternary) !Val {
    const elseLabel = try newLabel(allocator, context.name, "else");
    const endLabel = try newLabel(allocator, context.name, "end");
    const tag = try newVariable(allocator, context.name, tern.type.?);
    const dst: Val = .{ .Var = tag };

    const c = emitExpression(allocator, context, instructions, tern.condition.*);
    try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = c, .target = elseLabel } });

    const e1 = emitExpression(allocator, context, instructions, tern.thenStmt.*);
    try instructions.appendSlice(allocator, &.{
        .{ .Copy = .{ .src = e1, .dst = dst } },
        .{ .Jump = .{ .target = endLabel } },
        .{ .Label = .{ .identifier = elseLabel } },
    });

    const e2 = emitExpression(allocator, context, instructions, tern.elseStmt.*);
    try instructions.appendSlice(allocator, &.{
        .{ .Copy = .{ .src = e2, .dst = dst } },
        .{ .Label = .{ .identifier = endLabel } },
    });

    return dst;
}

fn emitUnary(allocator: Allocator, context: *Context, instructions: *Instructions, unary: Parser.Unary) !Val {
    const unaryExpr: Parser.Expression = unary.operand.*;
    const src = emitExpression(allocator, context, instructions, unaryExpr);
    const tag = try newVariable(allocator, context.name, unary.type.?);
    const dst: Val = .{ .Var = tag };
    switch (unary.operator) {
        .Inc, .Dec => {
            try instructions.appendSlice(allocator, switch (unary.order) {
                .Pre => &.{
                    .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = src } },
                    .{ .Copy = .{ .src = src, .dst = dst } },
                },
                .Post => &.{
                    .{ .Copy = .{ .src = src, .dst = dst } },
                    .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = src } },
                },
            });
        },
        else => {
            try instructions.append(allocator, .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = dst } });
        },
    }
    return dst;
}

fn emitStorageClassSymbols(allocator: Allocator) []TopLevel {
    var symbolDefs: ArrayList(TopLevel) = .empty;

    var symbolTableIt = SymbolTable.iterator();
    while (symbolTableIt.next()) |symbol| {
        const name = symbol.key_ptr.*;
        const entry = symbol.value_ptr.*;

        switch (entry.attrs) {
            .Static => |static| {
                switch (static.initialValue) {
                    .Initial => {
                        const staticVariable: TopLevel = .{ .StaticVariable = .{
                            .type = entry.type,
                            .identifier = name,
                            .global = static.global,
                            .init = static.initialValue,
                        } };
                        symbolDefs.append(allocator, staticVariable) catch allocError();
                    },
                    .Tentative => {
                        const staticVariable: TopLevel = .{ .StaticVariable = .{
                            .type = entry.type,
                            .identifier = name,
                            .global = static.global,
                            .init = static.initialValue,
                        } };
                        symbolDefs.append(allocator, staticVariable) catch allocError();
                    },
                    .None => {},
                }
            },
            else => {},
        }
    }
    return symbolDefs.toOwnedSlice(allocator) catch allocError();
}

pub fn newVariable(allocator: Allocator, name: []const u8, t: Parser.Type) ![]const u8 {
    const newName = nextTag(allocator, name);
    _ = t;
    // try self.map.put(name, .{ .type = t, .attrs = .Local });
    return newName;
}

pub fn newLabel(allocator: Allocator, name: []const u8, descr: []const u8) ![]const u8 {
    const label = try allocator.print("{s}.{s}.{d}", .{ name, descr, counter });
    counter += 1;
    return label;
}

fn nextTag(allocator: Allocator, name: []const u8) ![]const u8 {
    const tag = try allocator.print("{s}.{d}", .{ name, counter });
    counter += 1;
    return tag;
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
