const std = @import("std");
const print = std.debug.print;

const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const TAC = @import("TAC.zig");
const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

pub fn printLexerTokens(tokens: *TokenIterator) void {
    while (tokens.next()) |token| {
        std.debug.print("{any}: {s}\n", .{ token.type, token.symbol });
    }
}

pub fn printParserAST(ast: Parser.AST) void {
    const program = ast;
    const function = program.function;
    print("{any} (\n", .{@TypeOf(program)});
    print("  {any} (\n", .{@TypeOf(function)});
    for (function.body.items) |blockItem| {
        print("    {any} (\n", .{@TypeOf(blockItem)});
        switch (blockItem) {
            .Statement => |statement| printStatement(statement, 6),
            .Declaration => |decl| {
                print("      {any} (\n", .{@TypeOf(decl)});
                if (decl.initialize) |init| {
                    printExpression(init, 8);
                }
            },
        }
        print("    )\n", .{});
    }
    print("  )\n", .{});
    print(")\n", .{});
}

fn printStatement(statement: Parser.Statement, indent: usize) void {
    const indentStr = std.heap.page_allocator.alloc(u8, indent) catch allocError();
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    switch (statement) {
        .Expression => |expr| {
            print("{s}{any} (\n", .{ indentStr, @TypeOf(expr) });
            printExpression(expr, indent + 2);
        },
        .If => |if_| {
            print("{s}{any} (\n", .{ indentStr, @TypeOf(if_) });
            print("{s}  condition=\n", .{indentStr});
            printExpression(if_.condition, indent + 4);
            print("{s}  then=\n", .{indentStr});
            printStatement(if_.then.*, indent + 4);
            if (if_.else_ != null) {
                print("\n{s}  else=\n", .{indentStr});
                printStatement(if_.else_.?.*, indent + 4);
            }
        },
        .Return => |ret| {
            print("{s}{any} (", .{ indentStr, @TypeOf(ret) });
            print("\n{s}  {any} (expr=\n", .{ indentStr, @TypeOf(ret) });
            printExpression(ret.expr, indent + 4);
        },
        .Null => |nul| print("{s}{any} ()\n", .{ indentStr, @TypeOf(nul) }),
    }
}

fn printExpression(expr: Parser.Expression, indent: usize) void {
    const indentStr = std.heap.page_allocator.alloc(u8, indent) catch allocError();
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    print("{s}{s} (", .{ indentStr, @tagName(expr) });
    switch (expr) {
        .Constant => print("{s})\n", .{expr.Constant}),
        .Var => print("{s})\n", .{expr.Var.name}),
        .Unary => |unary| {
            print("\n", .{});
            print("\n{s}  operation={s}", .{ indentStr, @tagName(unary.operator) });
            print("\n{s}  factor=\n", .{indentStr});
            printExpression(unary.operand.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Binary => |binary| {
            print("\n", .{});
            print("{s}  left=\n", .{indentStr});
            printExpression(expr.Binary.left.*, indent + 4);
            print("{s}  operator={s}\n", .{ indentStr, @tagName(binary.operator) });
            print("{s}  right=\n", .{indentStr});
            printExpression(expr.Binary.right.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Assignment => |assign| {
            print("\n", .{});
            std.debug.print("{s}  lhs=\n", .{indentStr});
            printExpression(assign.lhs.*, indent + 4);
            std.debug.print("{s}  rhs=\n", .{indentStr});
            printExpression(assign.rhs.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Ternary => |ternary| {
            print("\n", .{});
            std.debug.print("{s}  condition=\n", .{indentStr});
            printExpression(ternary.condition.*, indent + 4);
            std.debug.print("{s}  then=\n", .{indentStr});
            printExpression(ternary.then.*, indent + 4);
            std.debug.print("{s}  else_=\n", .{indentStr});
            printExpression(ternary.else_.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
    }
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
                    .Constant => |src| print("src={any}({s}), ", .{ @TypeOf(src), src }),
                    .Var => |src| print("src={s}, ", .{src}),
                }
                switch (unary.dst) {
                    .Constant => |dst| print("src={any}({s})", .{ @TypeOf(dst), dst }),
                    .Var => |dst| print("dst={s}", .{dst}),
                }
                print(")\n", .{});
            },
            .Return => |ret| {
                switch (ret.val) {
                    .Constant => |factor| print("val={any}({s}))\n", .{ @TypeOf(factor), factor }),
                    .Var => |name| print("val={s})\n", .{name}),
                }
            },
            .Binary => |binary| {
                print("operator={any}, ", .{binary.operator});
                switch (binary.src1) {
                    .Constant => |src1| print("src1={s} ", .{src1}),
                    .Var => |src1| print("src1={s} ", .{src1}),
                }
                switch (binary.src2) {
                    .Constant => |src2| print("src2={s} ", .{src2}),
                    .Var => |src2| print("src2={s} ", .{src2}),
                }
                switch (binary.dst) {
                    .Constant => |dst| print("dst={s}", .{dst}),
                    .Var => |dst| print("dst={s}", .{dst}),
                }
                print(")\n", .{});
            },
            .Copy => |copy| {
                switch (copy.src) {
                    .Constant => |src| print("src={s} ", .{src}),
                    .Var => |src| print("src={s} ", .{src}),
                }
                switch (copy.dst) {
                    .Constant => |dst| print("dst={s}", .{dst}),
                    .Var => |dst| print("dst={s}", .{dst}),
                }
                print(")\n", .{});
            },
            .Label => |label| {
                print("name={s})\n", .{label.identifier});
            },
            .Jump => |jump| {
                print("label={s})\n", .{jump.target});
            },
            .JumpIfZero => |jump| {
                switch (jump.condition) {
                    .Constant => |cond| print("cond={any}({s}) ", .{ @TypeOf(cond), cond }),
                    .Var => |cond| print("cond={s} ", .{cond}),
                }
                print("label={s})\n", .{jump.target});
            },
            .JumpIfNotZero => |jump| {
                switch (jump.condition) {
                    .Constant => |cond| print("cond={any}({s}) ", .{ @TypeOf(cond), cond }),
                    .Var => |cond| print("cond={s} ", .{cond}),
                }
                print("label={s})\n", .{jump.target});
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
            .Ret, .Cqo => print(")", .{}),
            .Mov => |mov| {
                switch (mov.src) {
                    .Imm => |imm| print("src=Imm({s}) ", .{imm}),
                    .Pseudo => |reg| print("src=Pseudo({s}) ", .{reg}),
                    .Reg => |reg| print("src=Reg({s}) ", .{@tagName(reg)}),
                    .Stack => |stack| print("src=Stack({d}) ", .{stack}),
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
                print("int={d})", .{allocStack.stackPointer});
            },
            .Binary => |binary| {
                print("operator={s} ", .{@tagName(binary.operator)});
                switch (binary.src) {
                    .Imm => |imm| print("src=Imm({s}) ", .{imm}),
                    .Pseudo => |reg| print("src=Pseudo({s}) ", .{reg}),
                    .Reg => |reg| print("src=Reg({s}) ", .{@tagName(reg)}),
                    .Stack => |stack| print("src=Stack({d}) ", .{stack}),
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
                    .Stack => |stack| print("src=Stack({d})", .{stack}),
                }
            },
            .Cmp => |cmp| {
                std.debug.print("arg1={any}, arg2={any}", .{ cmp.arg1, cmp.arg2 });
            },
            .Jmp => |jmp| {
                std.debug.print("target={s}", .{jmp.target});
            },
            .JmpCC => |jmp| {
                std.debug.print("condition={s}, target={s}", .{ @tagName(jmp.condition), jmp.target });
            },
            .SetCC => |set| {
                switch (set.operand) {
                    .Imm => std.debug.print("condition={s}, target=Imm({d})", .{ @tagName(set.condition), set.operand.Stack }),
                    .Pseudo => std.debug.print("condition={s}, target=Pseudo({d})", .{ @tagName(set.condition), set.operand.Stack }),
                    .Reg => std.debug.print("condition={s}, target=Reg({d})", .{ @tagName(set.condition), set.operand.Stack }),
                    .Stack => std.debug.print("condition={s}, target=Stack({d})", .{ @tagName(set.condition), set.operand.Stack }),
                }
            },
            .Label => |label| {
                std.debug.print("id={s}", .{label.id});
            },
        }
        print(")\n", .{});
    }

    print("    ]\n", .{});
    print("  )\n", .{});
    print(")\n", .{});
}

fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.process.exit(1);
}
