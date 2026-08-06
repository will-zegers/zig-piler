const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fatal = std.process.fatal;

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
pub const IR = Program;

allocator: Allocator,

pub fn init(allocator: Allocator, ast: Parser.AST) IR {
    return .init(allocator, ast);
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, ast: Parser.AST) Program {
        return .{ .allocator = allocator, .function = .init(allocator, ast) };
    }
};

pub const Function = struct {
    const Labels = ArrayList([]const u8);
    const Tags = ArrayList([]const u8);
    const Instructions = ArrayList(Instruction);

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
                .Statement => switch (blockItem.Statement) {
                    .Return => |ret| {
                        const val = function.emitTac(ret.expr) catch allocError();
                        function.body.append(allocator, .{ .Return = .{ .val = val } }) catch allocError();
                    },
                    .Expression => |expr| _ = function.emitTac(expr) catch allocError(),
                    .Null => {},
                },
                .Declaration => |decl| {
                    if (decl.initialize) |initExpr| {
                        _ = function.emitTac(initExpr) catch allocError();
                    }
                },
            }
        }
        function.body.append(allocator, .{ .Return = .{ .val = .{ .Constant = "0" } } }) catch allocError();

        return function;
    }

    pub fn deinit(self: *Function) void {
        defer self.body.deinit(self.allocator);
        defer self.tags.deinit(self.allocator);
        defer self.labels.deinit(self.allocator);

        for (self.tags.items) |item| {
            self.allocator.free(item);
        }
        for (self.labels.items) |item| {
            self.allocator.free(item);
        }
    }

    fn emitTac(self: *Function, expr: Parser.Expression) !Val {
        switch (expr) {
            .Constant => return .{ .Constant = expr.Constant },
            .Var => return .{ .Var = expr.Var.name },
            .Unary => |unary| {
                const unaryExpr: Parser.Expression = unary.operand.*;
                const src = try self.emitTac(unaryExpr);
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

                        const v1 = try self.emitTac(binary.left.*);
                        try self.body.append(self.allocator, .{ .JumpIfZero = .{ .condition = v1, .target = falseLabel } });

                        const v2 = try self.emitTac(binary.right.*);
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

                        const v1 = try self.emitTac(binary.left.*);
                        try self.body.append(self.allocator, .{ .JumpIfNotZero = .{ .condition = v1, .target = trueLabel } });

                        const v2 = try self.emitTac(binary.right.*);
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
                        const src1 = try self.emitTac(
                            binary.left.*,
                        );
                        const src2 = try self.emitTac(
                            binary.right.*,
                        );
                        const dst: Val = .{ .Var = self.nextTag() };
                        try self.body.append(self.allocator, .{ .Binary = .{ .operator = binary.operator, .src1 = src1, .src2 = src2, .dst = dst } });
                        return dst;
                    },
                }
            },
            .Assignment => |assign| {
                const result = try self.emitTac(assign.rhs.*);
                const dst = try self.emitTac(assign.lhs.*);

                // If this is a compound assignment, we need to emit a binary instruction.
                // Otherwise, for simple assignments we just emit a copy.
                try self.body.append(self.allocator, if (assign.operator) |op|
                    .{ .Binary = .{ .operator = op, .src1 = dst, .src2 = result, .dst = dst } }
                else
                    .{ .Copy = .{ .src = result, .dst = dst } });

                return dst;
            },
        }
    }

    fn nextTag(self: *Function) []u8 {
        const tag = std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.name, self.tags.items.len }) catch allocError();
        self.tags.append(self.allocator, tag) catch allocError();
        return tag;
    }

    fn nextLabel(self: *Function, descr: []const u8) []u8 {
        const label = std.fmt.allocPrint(self.allocator, "{s}.{s}.{d}", .{ self.name, descr, self.labels.items.len }) catch allocError();
        self.labels.append(self.allocator, label) catch allocError();
        return label;
    }
};

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
