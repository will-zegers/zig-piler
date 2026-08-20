const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fatal = std.process.fatal;
const fmt = std.fmt;

const Parser = @import("Parser.zig");
const instruction = @import("TAC/instruction.zig");

pub const Binary = instruction.Binary;
pub const Copy = instruction.Copy;
pub const Instruction = instruction.Instruction;
pub const Jump = instruction.Jump;
pub const Label = instruction.Label;
pub const Return = instruction.Return;
pub const Unary = instruction.Unary;
const Val = instruction.Val;

pub const TAC = @This();

const Labels = ArrayList([]const u8);
const Tags = ArrayList([]const u8);
const Instructions = ArrayList(Instruction);

pub const Tacky = struct {
    allocator: Allocator,
    function: Function,
    tags: [][]const u8,
    labels: [][]const u8,

    pub fn deinit(self: *Tacky) void {
        for (self.tags) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.tags);

        for (self.labels) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.labels);

        self.function.deinit();
    }
};

allocator: Allocator,

pub fn init(allocator: Allocator, ast: Parser.AST) Tacky {
    var program: Program = .init(allocator, ast);
    return .{
        .allocator = allocator,
        .function = program.function,
        .tags = program.function.tags.toOwnedSlice(allocator) catch allocError(),
        .labels = program.function.labels.toOwnedSlice(allocator) catch allocError(),
    };
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, ast: Parser.AST) Program {
        return .{ .allocator = allocator, .function = .init(allocator, ast) };
    }

    pub fn deinit(self: *Program) void {
        self.function.deinit();
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: []const u8,
    body: ArrayList(Instruction),
    tags: Tags,
    labels: Labels,

    pub fn init(allocator: Allocator, ast: Parser.AST) Function {
        var function: Function = .{
            .allocator = allocator,
            .name = ast.function.name,
            .body = .empty,
            .tags = .empty,
            .labels = .empty,
        };

        for (ast.function.body.items) |blockItem| {
            switch (blockItem) {
                .Statement => |stmt| function.emitStatement(stmt) catch allocError(),
                .Declaration => |decl| {
                    if (decl.init) |initExpr| {
                        _ = function.emitExpression(initExpr) catch allocError();
                    }
                },
            }
        }
        function.body.append(allocator, .{ .Return = .{ .val = .{ .Constant = "0" } } }) catch allocError();

        return function;
    }

    pub fn deinit(self: *Function) void {
        defer self.body.deinit(self.allocator);
    }

    fn emitStatement(self: *Function, stmt: Parser.Statement) !void {
        const context = self.name;
        _ = context;
        switch (stmt) {
            .Compound => |compound| for (compound.items) |item| {
                switch (item) {
                    .Statement => try self.emitStatement(item.Statement),
                    .Declaration => |decl| {
                        if (decl.init) |initExpr| {
                            _ = self.emitExpression(initExpr) catch allocError();
                        }
                    },
                }
            },
            .Return => |ret| {
                const val = self.emitExpression(ret.expr) catch allocError();
                self.body.append(self.allocator, .{ .Return = .{ .val = val } }) catch allocError();
            },
            .Expression => |expr| _ = self.emitExpression(expr) catch allocError(),
            .Null => {},
            .If => |ifStmt| {
                const elseLabel = self.nextLabel("else");
                const endLabel = self.nextLabel("end");

                const c = try self.emitExpression(ifStmt.condition);
                try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = c, .target = elseLabel } });

                _ = try self.emitStatement(ifStmt.thenStmt.*);
                try self.body.append(self.allocator, .{ .Jump = .{ .target = endLabel } });

                try self.body.append(self.allocator, .{ .Label = .{ .identifier = elseLabel } });
                if (ifStmt.elseStmt) |elseStmt| _ = try self.emitStatement(elseStmt.*);

                try self.body.append(self.allocator, .{ .Label = .{ .identifier = endLabel } });
            },
            .Label => |lbl| {
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = lbl.tag } });
                _ = try self.emitStatement(lbl.body.*);
            },
            .Goto => |goto| try self.body.append(self.allocator, .{ .Jump = .{ .target = goto.target } }),
            .Break => |b| {
                const breakLabel = try self.allocator.print("{s}.break", .{b.tag});
                try self.labels.append(self.allocator, breakLabel);

                try self.body.append(self.allocator, .{ .Jump = .{ .target = breakLabel } });
            },
            .Continue => |c| {
                const continueLabel = try self.allocator.print("{s}.continue", .{c.tag});
                try self.labels.append(self.allocator, continueLabel);

                try self.body.append(self.allocator, .{ .Jump = .{ .target = continueLabel } });
            },
            .DoWhile => |d| {
                const startLabel = try self.allocator.print("{s}.start", .{d.tag});
                try self.labels.append(self.allocator, startLabel);
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = startLabel } });

                try self.emitStatement(d.body.*);

                const continueLabel = try self.allocator.print("{s}.continue", .{d.tag});
                try self.labels.append(self.allocator, continueLabel);
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = continueLabel } });

                const e = try self.emitExpression(d.cond);
                try self.body.append(self.allocator, .{ .JumpIfNotZero = .{ .condition = e, .target = startLabel } });

                const breakLabel = try self.allocator.print("{s}.break", .{d.tag});
                try self.labels.append(self.allocator, breakLabel);
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = breakLabel } });
            },
            .While => |w| {
                const continueLabel = try self.allocator.print("{s}.continue", .{w.tag});
                try self.labels.append(self.allocator, continueLabel);
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = continueLabel } });

                const e = try self.emitExpression(w.cond);

                const breakLabel = try self.allocator.print("{s}.break", .{w.tag});
                try self.labels.append(self.allocator, breakLabel);
                try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = e, .target = breakLabel } });

                try self.emitStatement(w.body.*);
                try self.body.append(self.allocator, .{ .Jump = .{ .target = continueLabel } });
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = breakLabel } });
            },
            .For => |f| {
                switch (f.init) {
                    .Declaration => |decl| if (decl.init) |declInit| {
                        _ = try self.emitExpression(declInit);
                    },
                    .Expression => |expr| if (expr) |exprInit| {
                        _ = try self.emitExpression(exprInit);
                    },
                }

                const startLabel = try self.allocator.print("{s}.start", .{f.tag});
                try self.labels.append(self.allocator, startLabel);
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = startLabel } });

                const breakLabel = try self.allocator.print("{s}.break", .{f.tag});
                try self.labels.append(self.allocator, breakLabel);

                if (f.cond) |cond| {
                    const e = try self.emitExpression(cond);
                    try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = e, .target = breakLabel } });
                } else {
                    try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = .{ .Constant = "1" }, .target = breakLabel } });
                }

                try self.emitStatement(f.body.*);

                const continueLabel = try self.allocator.print("{s}.continue", .{f.tag});
                try self.labels.append(self.allocator, continueLabel);
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = continueLabel } });

                if (f.post) |post| _ = try self.emitExpression(post);

                try self.body.append(self.allocator, .{ .Jump = .{ .target = startLabel } });
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = breakLabel } });
            },
            .Switch => |swtch| {
                const switchBreak = try self.allocator.print("{s}.break", .{swtch.tag});
                try self.labels.append(self.allocator, switchBreak);

                const c = try self.emitExpression(swtch.cond);
                const dst: Val = .{ .Var = self.nextTag() };

                for (swtch.cases.items) |case| {
                    if (case.*.cond) |cond| { // ignore 'default' for now
                        const e = try self.emitExpression(cond);
                        try self.body.append(self.allocator, .{ .Binary = .{ .operator = .Eq, .src1 = c, .src2 = e, .dst = dst } });
                        try self.body.append(self.allocator, .{ .JumpIfNotZero = .{ .condition = dst, .target = case.*.tag } });
                    }
                }
                // jump to the default statement if one exists, else to the end of the switch statement
                if (swtch.defaultTag) |defaultTag| {
                    try self.body.append(self.allocator, .{ .Jump = .{ .target = defaultTag } });
                } else {
                    try self.body.append(self.allocator, .{ .Jump = .{ .target = switchBreak } });
                }

                try self.emitStatement(swtch.body.*);

                try self.body.append(self.allocator, .{ .Label = .{ .identifier = switchBreak } });
            },
            .Case => |case| {
                try self.body.append(self.allocator, .{ .Label = .{ .identifier = case.tag } });
                if (case.body) |body| try self.emitStatement(body.*);
            },
        }
    }

    fn emitExpression(self: *Function, expr: Parser.Expression) !Val {
        switch (expr) {
            .Constant => return .{ .Constant = expr.Constant },
            .Var => return .{ .Var = expr.Var.name },
            .Unary => |unary| {
                const unaryExpr: Parser.Expression = unary.operand.*;
                const src = try self.emitExpression(unaryExpr);
                const dst: Val = .{ .Var = self.nextTag() };
                switch (unary.operator) {
                    .Inc, .Dec => {
                        self.body.appendSlice(self.allocator, switch (unary.type) {
                            .Pre => &.{
                                .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = src } },
                                .{ .Copy = .{ .src = src, .dst = dst } },
                            },
                            .Post => &.{
                                .{ .Copy = .{ .src = src, .dst = dst } },
                                .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = src } },
                            },
                        }) catch allocError();
                    },
                    else => {
                        try self.body.append(self.allocator, .{ .Unary = .{ .operator = unary.operator, .src = src, .dst = dst } });
                    },
                }
                return dst;
            },
            .Binary => |binary| {
                switch (binary.operator) {
                    .AndL => {
                        const falseLabel = self.nextLabel("andFalse");
                        const endLabel = self.nextLabel("andEnd");

                        const v1 = try self.emitExpression(binary.left.*);
                        try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = v1, .target = falseLabel } });

                        const v2 = try self.emitExpression(binary.right.*);
                        try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = v2, .target = falseLabel } });

                        const dst: Val = .{ .Var = self.nextTag() };
                        try self.body.appendSlice(self.allocator, &.{
                            .{ .Copy = .{ .src = .{ .Constant = "1" }, .dst = dst } },
                            .{ .Jump = .{ .target = endLabel } },
                            .{ .Label = .{ .identifier = falseLabel } },
                            .{ .Copy = .{ .src = .{ .Constant = "0" }, .dst = dst } },
                            .{ .Label = .{ .identifier = endLabel } },
                        });
                        return dst;
                    },
                    .OrL => {
                        const trueLabel = self.nextLabel("orTrue");
                        const endLabel = self.nextLabel("orEnd");

                        const v1 = try self.emitExpression(binary.left.*);
                        try self.body.append(self.allocator, .{ .JumpIfNotZero = .{ .condition = v1, .target = trueLabel } });

                        const v2 = try self.emitExpression(binary.right.*);
                        try self.body.append(self.allocator, .{ .JumpIfNotZero = .{ .condition = v2, .target = trueLabel } });

                        const dst: Val = .{ .Var = self.nextTag() };
                        try self.body.appendSlice(self.allocator, &.{
                            .{ .Copy = .{ .src = .{ .Constant = "0" }, .dst = dst } },
                            .{ .Jump = .{ .target = endLabel } },
                            .{ .Label = .{ .identifier = trueLabel } },
                            .{ .Copy = .{ .src = .{ .Constant = "1" }, .dst = dst } },
                            .{ .Label = .{ .identifier = endLabel } },
                        });
                        return dst;
                    },
                    else => {
                        const src1 = try self.emitExpression(
                            binary.left.*,
                        );
                        const src2 = try self.emitExpression(
                            binary.right.*,
                        );
                        const dst: Val = .{ .Var = self.nextTag() };
                        try self.body.append(self.allocator, .{ .Binary = .{ .operator = binary.operator, .src1 = src1, .src2 = src2, .dst = dst } });
                        return dst;
                    },
                }
            },
            .Assignment => |assign| {
                const result = try self.emitExpression(assign.rhs.*);
                const dst = try self.emitExpression(assign.lhs.*);

                // If this is a compound assignment, we need to emit a binary instruction.
                // Otherwise, for simple assignments we just emit a copy.
                try self.body.append(self.allocator, if (assign.operator) |op|
                    .{ .Binary = .{ .operator = op, .src1 = dst, .src2 = result, .dst = dst } }
                else
                    .{ .Copy = .{ .src = result, .dst = dst } });

                return dst;
            },
            .Ternary => |ternary| {
                const elseLabel = self.nextLabel("else");
                const endLabel = self.nextLabel("end");
                const dst: Val = .{ .Var = self.nextTag() };

                const c = try self.emitExpression(ternary.condition.*);
                try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = c, .target = elseLabel } });

                const e1 = try self.emitExpression(ternary.thenStmt.*);
                try self.body.appendSlice(self.allocator, &.{
                    .{ .Copy = .{ .src = e1, .dst = dst } },
                    .{ .Jump = .{ .target = endLabel } },
                    .{ .Label = .{ .identifier = elseLabel } },
                });

                const e2 = try self.emitExpression(ternary.elseStmt.*);
                try self.body.appendSlice(self.allocator, &.{
                    .{ .Copy = .{ .src = e2, .dst = dst } },
                    .{ .Label = .{ .identifier = endLabel } },
                });

                return dst;
            },
        }
    }

    fn nextTag(self: *Function) []u8 {
        const tag = self.allocator.print("{s}.{d}", .{ self.name, self.tags.items.len }) catch allocError();
        self.tags.append(self.allocator, tag) catch allocError();
        return tag;
    }

    fn nextLabel(self: *Function, descr: []const u8) []u8 {
        const label = self.allocator.print("{s}.{s}.{d}", .{ self.name, descr, self.labels.items.len }) catch allocError();
        self.labels.append(self.allocator, label) catch allocError();
        return label;
    }
};

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
