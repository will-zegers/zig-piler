const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const process = std.process;

const Parser = @import("../Parser.zig");
const AST = Parser.AST;
const Block = Parser.Block;
const Statement = Parser.Statement;

const Context = @import("Context.zig");

pub fn run(allocator: Allocator, context: *Context, tree: *AST) Allocator.Error!void {
    for (tree.declarations) |*decl| {
        if (decl.* != .FunDecl) continue;

        if (decl.FunDecl.body) |*body| {
            context.function = decl.FunDecl.name;
            defer context.function = null;

            try labelBlockLoops(allocator, context, body);
        }
    }
}

fn labelBlockLoops(allocator: Allocator, context: *Context, block: *Block) Allocator.Error!void {
    for (block.items) |*item| {
        switch (item.*) {
            .Statement => |*stmt| try labelStatementLoops(allocator, context, stmt),
            else => {},
        }
    }
}

fn labelStatementLoops(allocator: Allocator, context: *Context, stmt: *Statement) Allocator.Error!void {
    switch (stmt.*) {
        .Compound => |*compound| try labelBlockLoops(allocator, context, compound),
        .Goto => |*goto| {
            goto.target = try context.getGotoLabel(goto) orelse return;
        },
        .If => |*ifStmt| {
            try labelStatementLoops(allocator, context, ifStmt.thenStmt);
            if (ifStmt.elseStmt) |*elseStmt| try labelStatementLoops(allocator, context, elseStmt.*);
        },
        .Switch => |*swtch| try labelStatementLoops(allocator, context, swtch.body),
        .Case => |*case| if (case.body) |body| try labelStatementLoops(allocator, context, body),
        .Label => |*label| try labelStatementLoops(allocator, context, label.body),
        .DoWhile => |*loop| try labelStatementLoops(allocator, context, loop.body),
        .For => |*loop| try labelStatementLoops(allocator, context, loop.body),
        .While => |*loop| try labelStatementLoops(allocator, context, loop.body),
        else => {},
    }
}
