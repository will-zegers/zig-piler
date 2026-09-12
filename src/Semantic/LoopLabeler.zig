const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const process = std.process;

const Parser = @import("../Parser.zig");
const AST = Parser.AST;
const Block = Parser.Block;
const Statement = Parser.Statement;

const Context = @import("Context.zig");

pub fn run(allocator: Allocator, context: *Context, ast: *AST) void {
    for (ast.tree.functions) |*function| {
        if (function.body) |*body| {
            context.function = function.name;
            defer context.function = null;

            labelBlockLoops(allocator, context, body);
        }
    }
}

fn labelBlockLoops(allocator: Allocator, context: *Context, block: *Block) void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| labelStatementLoops(allocator, context, stmt),
            else => {},
        }
    }
}

fn labelStatementLoops(allocator: Allocator, context: *Context, stmt: *Statement) void {
    switch (stmt.*) {
        .Compound => |*compound| labelBlockLoops(allocator, context, compound),
        .Goto => |*goto| {
            goto.target = context.getUniqueLabel(goto.target);
        },
        .If => |*ifStmt| {
            labelStatementLoops(allocator, context, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |*elseStmt| labelStatementLoops(allocator, context, elseStmt.*);
        },
        .Switch => |*swtch| labelStatementLoops(allocator, context, swtch.body),
        .Case => |*case| if (case.body) |body| labelStatementLoops(allocator, context, body),
        .Label => |*label| labelStatementLoops(allocator, context, label.body),
        .DoWhile => |*loop| labelStatementLoops(allocator, context, loop.body),
        .For => |*loop| labelStatementLoops(allocator, context, loop.body),
        .While => |*loop| labelStatementLoops(allocator, context, loop.body),
        else => {},
    }
}
