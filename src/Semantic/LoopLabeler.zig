const std = @import("std");
const log = std.log;
const process = std.process;

const Parser = @import("../Parser.zig");
const AST = Parser.AST;
const Block = Parser.Block;
const Statement = Parser.Statement;

const Context = @import("Context.zig");

pub fn run(context: Context, ast: *AST) void {
    for (ast.tree.functions) |*function| {
        if (function.body) |*body| {
            labelBlockLoops(context, body);
        }
    }
}

fn labelBlockLoops(context: Context, block: *Block) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| labelStatementLoops(context, stmt),
            else => {},
        }
    }
}

fn labelStatementLoops(context: Context, stmt: *Statement) void {
    switch (stmt.*) {
        .Compound => |*compound| labelBlockLoops(context, compound),
        .Goto => |*goto| {
            if (context.labels.get(goto.target)) |entry| {
                goto.target = entry.unique;
            } else {
                log.err("Use of undeclared identifier '{s}'", .{goto.target});
                process.exit(1);
            }
        },
        .If => |*ifStmt| {
            labelStatementLoops(context, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |*elseStmt| labelStatementLoops(context, elseStmt.*);
        },
        .Switch => |*swtch| labelStatementLoops(context, swtch.body),
        .Case => |*case| if (case.body) |body| labelStatementLoops(context, body),
        .Label => |*label| labelStatementLoops(context, label.body),
        .DoWhile => |*loop| labelStatementLoops(context, loop.body),
        .For => |*loop| labelStatementLoops(context, loop.body),
        .While => |*loop| labelStatementLoops(context, loop.body),
        else => {},
    }
}
