const std = @import("std");
const print = std.debug.print;

const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
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
    print("    {any} (\n", .{@TypeOf(body)});
    print("      type={any} expr=\n", .{body.type});
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

    print("{any} (\n", .{@TypeOf(expr)});
    print("{s}  type={any}\n", .{ indentStr, expr.type });
    if (expr.value) |value| print("{s}  value={s})\n", .{ indentStr, value });
    if (expr.opType) |opType| print("{s}  opType={any})\n", .{ indentStr, opType });
    if (expr.child) |child| {
        print("{s}  child=", .{indentStr});
        try printExprHierarchy(child.*, indent + 2);
    }
    print("{s})\n", .{indentStr});
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
