const std = @import("std");
const print = std.debug.print;

const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const TAC = @import("TAC.zig");
const Token = @import("token.zig").Token;

pub fn printLexerTokens(tokens: []Token) void {
    for (tokens) |token| {
        std.debug.print("{any}: {s}\n", .{ token.type, token.value });
    }
}

pub fn printParserAST(ast: Parser.AST) void {
    const program = ast;
    const function = program.function;
    const body = function.body;
    const expr = body.expr;
    print("{any} (\n", .{@TypeOf(program)});
    print("  {any} (\n", .{@TypeOf(function)});
    print("    {any} (\n", .{body.tag});
    print("      expr=", .{});
    printExprHierarchy(expr, 6) catch {};
    print("    )\n", .{});
    print("  )\n", .{});
    print(")\n", .{});
}

fn printExprHierarchy(expr: Parser.Expression, indent: usize) !void {
    const indentStr = try std.heap.page_allocator.alloc(u8, indent);
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    print("{s} (\n", .{@tagName(expr)});
    switch (expr) {
        .Constant => |constant| {
            print("{s}  int={s})\n", .{ indentStr, constant.int });
        },
        .Unary => |unary| {
            print("{s}  operation={s})\n", .{ indentStr, @tagName(unary.operator) });
            print("{s}  expr=", .{indentStr});
            try printExprHierarchy(unary.expr.*, indent + 2);
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
    print("    identifier={s}\n", .{function.identifier});
    print("    body=\n", .{});
    for (body.items) |instr| {
        print("      {s} (", .{@tagName(instr)});
        switch (instr) {
            .Unary => |unary| {
                print("operator={any}, ", .{unary.operator});
                switch (unary.src) {
                    .expr => |expr| print("src={s}({s}), ", .{ @tagName(expr), expr.Constant.int }),
                    .name => |name| print("src={s}, ", .{name}),
                }
                switch (unary.dst) {
                    .expr => |expr| print("src={s}({s})", .{ @tagName(expr), expr.Constant.int }),
                    .name => |name| print("dst={s}", .{name}),
                }
                print(")\n", .{});
            },
            .Return => |ret| {
                switch (ret.val) {
                    .expr => |expr| print("val={s}({s}))\n", .{ @tagName(expr), expr.Constant.int }),
                    .name => |name| print("val={s})\n", .{name}),
                }
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

    print("{any} (", .{@TypeOf(program)});
    print("  {any} (\n", .{@TypeOf(function)});
    print("    name={s}\n", .{function.name});
    print("    instructions= (\n", .{});

    for (function.instructions) |instr| {
        print("      {any} (\n", .{@TypeOf(instr)});
        print("        mnemonic={any}\n", .{instr.mnemonic});
        if (instr.src) |src| {
            switch (src) {
                .Imm => print("        src=Imm({s})\n", .{src.Imm}),
                .Reg => print("        src=Reg({s})\n", .{@tagName(src.Reg)}),
            }
        }
        if (instr.dst) |dst| {
            switch (dst) {
                .Imm => print("        dst=Imm({s})\n", .{dst.Imm}),
                .Reg => print("        dst=Reg({s})\n", .{@tagName(dst.Reg)}),
            }
        }
    }

    print("  )\n", .{});
    print(")\n", .{});
}
