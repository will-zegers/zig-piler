const std = @import("std");
const print = std.debug.print;

const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const TAC = @import("TAC.zig");
const Token = @import("Lexer.zig").Token;

pub fn printLexerTokens(tokens: []Token) void {
    for (tokens) |token| {
        std.debug.print("{any}: {s}\n", .{ token.type, token.symbol });
    }
}

pub fn printParserAST(ast: Parser.AST) void {
    const program = ast;
    const function = program.function;
    const body = function.body;
    const expr = body.expr;
    print("{any} (\n", .{@TypeOf(program)});
    print(". {any} (\n", .{@TypeOf(function)});
    print(". . {any} (\n", .{body.tag});
    print(". . . expr=\n", .{});
    printExpression(expr, 8) catch {};
    print(". . )\n", .{});
    print(". )\n", .{});
    print(")\n", .{});
}

fn printExpression(expr: Parser.Expression, indent: usize) !void {
    const indentStr = try std.heap.page_allocator.alloc(u8, indent);
    for (indentStr, 0..) |_, i| {
        indentStr[i] = if (i % 2 == 0) '.' else ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    print("{s}{s} (\n", .{ indentStr, @tagName(expr) });
    switch (expr) {
        .Factor => {
            try printFactor(expr.Factor, indent + 2);
        },
        .Binary => |binary| {
            print("{s}. left=\n", .{indentStr});
            try printExpression(expr.Binary.left.*, indent + 6);
            print("{s}. operator={s}\n", .{ indentStr, @tagName(binary.operator) });
            print("{s}. right=\n", .{indentStr});
            try printExpression(expr.Binary.right.*, indent + 6);
        },
    }
    print("{s})\n", .{indentStr});
}

fn printFactor(factor: Parser.Factor, indent: usize) !void {
    const indentStr = try std.heap.page_allocator.alloc(u8, indent);
    for (indentStr, 0..) |_, i| {
        indentStr[i] = if (i % 2 == 0) '.' else ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    print("{s}{s} (\n", .{ indentStr, @tagName(factor) });
    switch (factor) {
        .Constant => |constant| {
            print("{s}. int={s})\n", .{ indentStr, constant.int });
        },
        .Unary => |unary| {
            print("{s}. operation={s})\n", .{ indentStr, @tagName(unary.operator) });
            print("{s}. factor=", .{indentStr});
            try printFactor(unary.factor.*, indent + 2);
        },
        .Parantheses => {
            print("{s}. (...\n", .{indentStr});
            print("{s}. ...)\n", .{indentStr});
        },
    }
    print("{s})\n", .{indentStr});
}

pub fn printTAC(ir: TAC.IR) void {
    const program = ir;
    const function = program.function;
    const body = function.body;
    print("{any} (\n", .{@TypeOf(program)});
    print("  {any} (\n", .{@TypeOf(function)});
    print("    name={s}\n", .{function.name});
    print("    body=\n", .{});
    for (body.items) |instr| {
        print("      {s} (", .{@tagName(instr)});
        switch (instr) {
            .Unary => |unary| {
                print("operator={any}, ", .{unary.operator});
                switch (unary.src) {
                    .Constant => |src| print("src={any}({s}), ", .{ @TypeOf(src), src.int }),
                    .Var => |src| print("src={s}, ", .{src}),
                }
                switch (unary.dst) {
                    .Constant => |dst| print("src={any}({s})", .{ @TypeOf(dst), dst.int }),
                    .Var => |dst| print("dst={s}", .{dst}),
                }
                print(")\n", .{});
            },
            .Return => |ret| {
                switch (ret.val) {
                    .Constant => |factor| print("val={any}({s}))\n", .{ @TypeOf(factor), factor.int }),
                    .Var => |name| print("val={s})\n", .{name}),
                }
            },
            .Binary => |binary| {
                print("operator={any}, ", .{binary.operator});
                switch (binary.src1) {
                    .Constant => |src1| print("src1={any}({s}) ", .{ @TypeOf(src1), src1.int }),
                    .Var => |src1| print("src1={s} ", .{src1}),
                }
                switch (binary.src2) {
                    .Constant => |src2| print("right={any}({s}) ", .{ @TypeOf(src2), src2.int }),
                    .Var => |src2| print("right={s} ", .{src2}),
                }
                switch (binary.dst) {
                    .Constant => |dst| print("dst={any}({s})", .{ @TypeOf(dst), dst.int }),
                    .Var => |dst| print("dst={s}", .{dst}),
                }
                print(")\n", .{});
            },
        }
    }
    print("    )\n", .{});
    print("  )\n", .{});
    print(")\n", .{});
}

pub fn printAssemblerAST(ast: Assembler.AST) void {
    const program = ast;
    const function = program.function;

    print("{any} (\n", .{@TypeOf(program)});
    print("  {any} (\n", .{@TypeOf(function)});
    print("    name={s}\n", .{function.name});
    print("    instructions=[\n", .{});

    for (function.instructions.items) |instr| {
        print("      {s} (", .{@tagName(instr)});
        switch (instr) {
            .Mov => |mov| {
                switch (mov.src) {
                    .Imm => |imm| print("src=Imm({s}) ", .{imm}),
                    .Pseudo => |reg| print("src=Pseudo({s}) ", .{reg}),
                    .Reg => |reg| print("src=Reg({s}) ", .{@tagName(reg)}),
                    .Stack => |stack| print("dst=Stack({d}) ", .{stack}),
                }
                switch (mov.dst) {
                    .Imm => |imm| print("dst=Imm({s})", .{imm}),
                    .Pseudo => |reg| print("dst=Pseudo({s})", .{reg}),
                    .Reg => |reg| print("dst=Reg({s})", .{@tagName(reg)}),
                    .Stack => |stack| print("dst=Stack({d})", .{stack}),
                }
            },
            .Unary => |unary| {
                print("operator={s} ", .{@tagName(unary.operator)});
                switch (unary.operand) {
                    .Imm => |imm| print("dst=Imm({s})", .{imm}),
                    .Pseudo => |reg| print("dst=Pseudo({s})", .{reg}),
                    .Reg => |reg| print("dst=Reg({s})", .{@tagName(reg)}),
                    .Stack => |stack| print("dst=Stack({d})", .{stack}),
                }
            },
            .AllocStack => |allocStack| {
                print("int={d}", .{allocStack.stackPointer});
            },
            .Binary => |binary| {
                print("operator={s} ", .{@tagName(binary.operator)});
                switch (binary.src) {
                    .Imm => |imm| print("src=Imm({s}) ", .{imm}),
                    .Pseudo => |reg| print("src=Pseudo({s}) ", .{reg}),
                    .Reg => |reg| print("src=Reg({s}) ", .{@tagName(reg)}),
                    .Stack => |stack| print("dst=Stack({d}) ", .{stack}),
                }
                switch (binary.dst) {
                    .Imm => |imm| print("dst=Imm({s})", .{imm}),
                    .Pseudo => |reg| print("dst=Pseudo({s})", .{reg}),
                    .Reg => |reg| print("dst=Reg({s})", .{@tagName(reg)}),
                    .Stack => |stack| print("dst=Stack({d})", .{stack}),
                }
            },
            .Idiv => |idiv| {
                switch (idiv.operand) {
                    .Imm => |imm| print("src=Imm({s})", .{imm}),
                    .Pseudo => |reg| print("src=Pseudo({s})", .{reg}),
                    .Reg => |reg| print("src=Reg({s})", .{@tagName(reg)}),
                    .Stack => |stack| print("dst=Stack({d})", .{stack}),
                }
            },
            else => {},
        }
        print(")\n", .{});
    }

    print("    ]\n", .{});
    print("  )\n", .{});
    print(")\n", .{});
}
