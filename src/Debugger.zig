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
    print("{any} (", .{@TypeOf(program)});
    print("  {any} (\n", .{@TypeOf(function)});
    print("      {any} (\n", .{@TypeOf(body)});
    print("        type={any} expr=\n", .{body.type});
    print("        expr=\n", .{});
    print("          {any} (\n", .{@TypeOf(expr)});
    print("            type={any}\n", .{expr.type});
    print("            value={s})\n", .{expr.value});
    print("          )\n", .{});
    print("      )\n", .{});
    print("  )\n", .{});
    print(")", .{});
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
    print(")", .{});
}
