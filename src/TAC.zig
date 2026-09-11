const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Parser = @import("Parser.zig");
const instr = @import("TAC/instruction.zig");

pub const Binary = instr.Binary;
pub const Copy = instr.Copy;
pub const Instruction = instr.Instruction;
pub const Jump = instr.Jump;
pub const Label = instr.Label;
pub const Return = instr.Return;
pub const Unary = instr.Unary;
const Val = instr.Val;

pub const TAC = @This();

const Labels = ArrayList([]const u8);
const Tags = ArrayList([]const u8);
const Instructions = ArrayList(Instruction);

pub const Tacky = struct {
    arena: ArenaAllocator,
    functions: []Function,

    pub fn deinit(self: *Tacky) void {
        self.arena.deinit();
    }
};

pub fn emit(allocator: Allocator, ast: Parser.AST) Tacky {
    // This will be doing a lot of miscellaneous allocations for tags and labels,
    // so just handle clean-up with an arena instead of meticulous bookkeeping
    var arena: ArenaAllocator = .init(allocator);
    const program: Program = .emit(arena.allocator(), ast);

    return .{ .arena = arena, .functions = program.functions };
}

const Program = struct {
    allocator: Allocator,
    functions: []Function,

    pub fn emit(allocator: Allocator, ast: Parser.AST) Program {
        var functions: ArrayList(Function) = .empty;
        for (ast.tree.functions) |function| {
            functions.append(allocator, .emit(allocator, function)) catch allocError();
        }
        return .{ .allocator = allocator, .functions = functions.toOwnedSlice(allocator) catch allocError() };
    }
};

const Context = struct {
    name: []const u8,
    counter: usize = 0,
};

pub const Function = struct {
    name: []const u8,
    body: ArrayList(Instruction),

    pub fn emit(allocator: Allocator, function: Parser.FunDecl) Function {
        var context: Context = .{ .name = function.name, .counter = 0 };

        var instructions: Instructions = .empty;
        if (function.body) |body| {
            emitBlock(allocator, &context, &instructions, body) catch allocError();
        }

        instructions.append(allocator, .{ .Return = .{ .val = .{ .Constant = "0" } } }) catch allocError();

        return .{ .name = function.name, .body = instructions };
    }
};

fn emitBlock(allocator: Allocator, context: *Context, instructions: *Instructions, block: Parser.Block) !void {
    for (block.items) |item| {
        switch (item) {
            .Declaration => |decl| try emitDeclaration(allocator, context, instructions, decl),
            .Statement => |stmt| try emitStatement(allocator, context, instructions, stmt),
        }
    }
}

fn emitDeclaration(allocator: Allocator, context: *Context, body: *Instructions, decl: Parser.Declaration) !void {
    switch (decl) {
        .VarDecl => |varDecl| {
            if (varDecl.init) |initExpr| {
                _ = try emitExpression(allocator, context, body, initExpr);
            }
        },
        .FunDecl => unreachable,
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
            const val = try emitExpression(allocator, context, instructions, ret.expr);
            try instructions.append(allocator, .{ .Return = .{ .val = val } });
        },
        .Expression => |expr| _ = try emitExpression(allocator, context, instructions, expr),
        .Null => {},
        .If => |ifStmt| {
            const elseLabel = nextLabel(allocator, context, "else");
            const endLabel = nextLabel(allocator, context, "end");

            const c = try emitExpression(allocator, context, instructions, ifStmt.condition);
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

            const e = try emitExpression(allocator, context, instructions, d.cond);
            try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = e, .target = startLabel } });

            const breakLabel = try allocator.print("{s}.break", .{d.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = breakLabel } });
        },
        .While => |w| {
            const continueLabel = try allocator.print("{s}.continue", .{w.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = continueLabel } });

            const e = try emitExpression(allocator, context, instructions, w.cond);

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
                    _ = try emitExpression(allocator, context, instructions, exprInit);
                },
            }

            const startLabel = try allocator.print("{s}.start", .{f.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = startLabel } });

            const breakLabel = try allocator.print("{s}.break", .{f.tag.?});

            if (f.cond) |cond| {
                const e = try emitExpression(allocator, context, instructions, cond);
                try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = e, .target = breakLabel } });
            } else {
                try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = .{ .Constant = "1" }, .target = breakLabel } });
            }

            try emitStatement(allocator, context, instructions, f.body.*);

            const continueLabel = try allocator.print("{s}.continue", .{f.tag.?});
            try instructions.append(allocator, .{ .Label = .{ .identifier = continueLabel } });

            if (f.post) |post| _ = try emitExpression(allocator, context, instructions, post);

            try instructions.append(allocator, .{ .Jump = .{ .target = startLabel } });
            try instructions.append(allocator, .{ .Label = .{ .identifier = breakLabel } });
        },
        .Switch => |swtch| {
            const switchBreak = try allocator.print("{s}.break", .{swtch.tag.?});

            const c = try emitExpression(allocator, context, instructions, swtch.cond);
            const dst: Val = .{ .Var = nextTag(allocator, context) };

            for (swtch.cases.items) |case| {
                if (case.cond) |cond| { // ignore 'default' for now
                    const e = try emitExpression(allocator, context, instructions, cond);
                    try instructions.append(allocator, .{ .Binary = .{ .operator = .Eq, .src1 = c, .src2 = e, .dst = dst } });
                    try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = dst, .target = case.tag.? } });
                }
            }
            // jump to the default statement if one exists, else to the end of the switch statement
            if (swtch.defaultTag) |defaultTag| {
                try instructions.append(allocator, .{ .Jump = .{ .target = defaultTag } });
            } else {
                try instructions.append(allocator, .{ .Jump = .{ .target = switchBreak } });
            }

            try emitStatement(allocator, context, instructions, swtch.body.*);

            try instructions.append(allocator, .{ .Label = .{ .identifier = switchBreak } });
        },
        .Case => |case| {
            try instructions.append(allocator, .{ .Label = .{ .identifier = case.tag.? } });
            if (case.body) |body| try emitStatement(allocator, context, instructions, body.*);
        },
    }
}

fn emitExpression(allocator: Allocator, context: *Context, instructions: *Instructions, expr: Parser.Expression) !Val {
    switch (expr) {
        .Constant => return .{ .Constant = expr.Constant },
        .Var => return .{ .Var = expr.Var.name },
        .Unary => |unary| return emitUnary(allocator, context, instructions, unary),
        .Binary => |binary| return emitBinary(allocator, context, instructions, binary),
        .Assignment => |assign| return emitAssignment(allocator, context, instructions, assign),
        .Ternary => |ternary| return emitTernary(allocator, context, instructions, ternary),
        .FunctionCall => unreachable,
    }
}

fn emitUnary(allocator: Allocator, context: *Context, instructions: *Instructions, unary: Parser.Unary) void {
    const unaryExpr: Parser.Expression = unary.operand.*;
    const src = try emitExpression(allocator, context, instructions, unaryExpr);
    const dst: Val = .{ .Var = nextTag(allocator, context) };
    switch (unary.operator) {
        .Inc, .Dec => {
            try instructions.appendSlice(allocator, switch (unary.type) {
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
            try body.append(allocator, .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = dst } });
        },
    }
    return dst;
}

fn emitBinary(allocator: Allocator, context: *Context, instructions: *Instructions, binary: Parser.Binary) void {
    switch (binary.operator) {
        .AndL => {
            const falseLabel = nextLabel(allocator, context, "andFalse");
            const endLabel = nextLabel(allocator, context, "andEnd");

            const v1 = try emitExpression(allocator, context, instructions, binary.left.*);
            try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = v1, .target = falseLabel } });

            const v2 = try emitExpression(allocator, context, instructions, binary.right.*);
            try instructions.append(allocator, .{ .JumpIfZero = .{ .condition = v2, .target = falseLabel } });

            const dst: Val = .{ .Var = nextTag(allocator, context) };
            try instructions.appendSlice(allocator, &.{
                .{ .Copy = .{ .src = .{ .Constant = "1" }, .dst = dst } },
                .{ .Jump = .{ .target = endLabel } },
                .{ .Label = .{ .identifier = falseLabel } },
                .{ .Copy = .{ .src = .{ .Constant = "0" }, .dst = dst } },
                .{ .Label = .{ .identifier = endLabel } },
            });
            return dst;
        },
        .OrL => {
            const trueLabel = nextLabel(allocator, context, "orTrue");
            const endLabel = nextLabel(allocator, context, "orEnd");

            const v1 = try emitExpression(allocator, context, instructions, binary.left.*);
            try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = v1, .target = trueLabel } });

            const v2 = try emitExpression(allocator, context, instructions, binary.right.*);
            try instructions.append(allocator, .{ .JumpIfNotZero = .{ .condition = v2, .target = trueLabel } });

            const dst: Val = .{ .Var = nextTag(allocator, context) };
            try instructions.appendSlice(allocator, &.{
                .{ .Copy = .{ .src = .{ .Constant = "0" }, .dst = dst } },
                .{ .Jump = .{ .target = endLabel } },
                .{ .Label = .{ .identifier = trueLabel } },
                .{ .Copy = .{ .src = .{ .Constant = "1" }, .dst = dst } },
                .{ .Label = .{ .identifier = endLabel } },
            });
            return dst;
        },
        else => {
            const src1 = try emitExpression(allocator, context, instructions, binary.left.*);
            const src2 = try emitExpression(allocator, context, instructions, binary.right.*);
            const dst: Val = .{ .Var = nextTag(allocator, context) };
            try instructions.append(allocator, .{ .Binary = .{ .operator = binary.operator, .src1 = src1, .src2 = src2, .dst = dst } });
            return dst;
        },
    }
}

fn emitAssignment(allocator: Allocator, context: *Context, instructions: *Instructions, assign: Parser.Assignment) void {
    const result = try emitExpression(allocator, context, instructions, assign.rhs.*);
    const dst = try emitExpression(allocator, context, instructions, assign.lhs.*);

    // If this is a compound assignment, we need to emit a binary instruction.
    // Otherwise, for simple assignments we just emit a copy.
    try instructions.append(allocator, if (assign.operator) |op|
        .{ .Binary = .{ .operator = op, .src1 = dst, .src2 = result, .dst = dst } }
    else
        .{ .Copy = .{ .src = result, .dst = dst } });

    return dst;
}

fn emitTernary(allocator: Allocator, context: *Context, instructions: *Instructions, tern: Parser.Ternary) void {
    const elseLabel = nextLabel(allocator, context, "else");
    const endLabel = nextLabel(allocator, context, "end");
    const dst: Val = .{ .Var = nextTag(allocator, context) };

    const c = try emitExpression(allocator, context, body, ternary.condition.*);
    try body.append(allocator, .{ .JumpIfZero = .{ .condition = c, .target = elseLabel } });

    const e1 = try emitExpression(allocator, context, body, ternary.thenStmt.*);
    try body.appendSlice(allocator, &.{
        .{ .Copy = .{ .src = e1, .dst = dst } },
        .{ .Jump = .{ .target = endLabel } },
        .{ .Label = .{ .identifier = elseLabel } },
    });

    const e2 = try emitExpression(allocator, context, body, ternary.elseStmt.*);
    try body.appendSlice(allocator, &.{
        .{ .Copy = .{ .src = e2, .dst = dst } },
        .{ .Label = .{ .identifier = endLabel } },
    });

    return dst;
}

fn nextTag(allocator: Allocator, context: *Context) []u8 {
    const tag = allocator.print("{s}.{d}", .{ context.name, context.counter }) catch allocError();
    context.counter += 1;
    return tag;
}

fn nextLabel(allocator: Allocator, context: *Context, descr: []const u8) []u8 {
    const label = allocator.print("{s}.{s}.{d}", .{ context.name, descr, context.counter }) catch allocError();
    context.counter += 1;
    return label;
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
