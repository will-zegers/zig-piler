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
    const functions = ast.tree.functions;
    print("{any}(\n", .{@TypeOf(ast.tree)});
    for (functions) |function| {
        printDeclaration(.{ .FunDecl = function }, 4);
    }
    print("  )\n", .{});
    print(")\n", .{});
}

fn printBlockItem(blockItem: Parser.BlockItem, indent: usize) void {
    const indentStr = std.heap.page_allocator.alloc(u8, indent) catch allocError();
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    switch (blockItem) {
        .Statement => |statement| printStatement(statement, indent),
        .Declaration => |decl| printDeclaration(decl, indent),
    }
}

fn printDeclaration(decl: Parser.Declaration, indent: usize) void {
    const indentStr = std.heap.page_allocator.alloc(u8, indent) catch allocError();
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }

    switch (decl) {
        .VarDecl => |varDecl| {
            print("{s}{any}(", .{ indentStr, @TypeOf(varDecl) });
            if (varDecl.init) |init| {
                print("\n", .{});
                printExpression(init, indent + 2);
                print("{s})\n", .{indentStr});
            } else {
                print("{s}{s})\n", .{ indentStr, varDecl.name });
            }
        },
        .FunDecl => |funDecl| {
            print("{s}{any} {s}(", .{ indentStr, @TypeOf(funDecl), funDecl.name });
            for (funDecl.params) |param| {
                print("{s} ", .{param});
            }
            print(")\n", .{});
            if (funDecl.body) |body| {
                printStatement(.{ .Compound = body }, indent + 2);
            } else print(");\n", .{});
            print("{s})\n", .{indentStr});
        },
    }
}

fn printStatement(statement: Parser.Statement, indent: usize) void {
    const indentStr = std.heap.page_allocator.alloc(u8, indent) catch allocError();
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    switch (statement) {
        .Compound => |compound| {
            print("{s}{{\n", .{indentStr});
            for (compound.items) |item| {
                printBlockItem(item, indent + 2);
            }
            print("{s}}}\n", .{indentStr});
        },
        .Expression => |expr| {
            printExpression(expr, indent);
        },
        .If => |ifStmt| {
            print("{s}{any}(\n", .{ indentStr, @TypeOf(ifStmt) });
            print("{s}  condition:\n", .{indentStr});
            printExpression(ifStmt.condition, indent + 4);
            print("{s}  thenStmt:\n", .{indentStr});
            printStatement(ifStmt.thenStmt.*, indent + 4);
            if (ifStmt.elseStmt != null) {
                print("{s}  else:\n", .{indentStr});
                printStatement(ifStmt.elseStmt.?.*, indent + 4);
            }
            print("{s})\n", .{indentStr});
        },
        .Return => |ret| {
            print("{s}{any}(\n", .{ indentStr, @TypeOf(ret) });
            printExpression(ret.expr, indent + 2);
            print("{s})\n", .{indentStr});
        },
        .Null => |nul| print("{s}{any}()\n", .{ indentStr, @TypeOf(nul) }),
        .Label => |lbl| {
            print("{s}{any}(\n", .{ indentStr, @TypeOf(lbl) });
            print("{s}  name: {s}\n", .{ indentStr, lbl.name });
            print("{s}  tag: {s}\n", .{ indentStr, if (lbl.tag) |tag| tag else "null" });
            print("{s}  statement:\n", .{indentStr});
            printStatement(lbl.body.*, indent + 4);
        },
        .Goto => |goto| print("{s}{any}(label: {s})\n", .{ indentStr, @TypeOf(goto), goto.target }),
        .Break => |b| {
            print("{s}{any}({s})\n", .{ indentStr, @TypeOf(b), if (b.tag) |tag| tag else "null" });
        },
        .Continue => |c| {
            print("{s}{any}({s})\n", .{ indentStr, @TypeOf(c), if (c.tag) |tag| tag else "null" });
        },
        .DoWhile => |dw| {
            print("{s}{any}( {s}\n", .{ indentStr, @TypeOf(dw), if (dw.tag) |tag| tag else "null" });
            print("  {s}body:\n", .{indentStr});
            printStatement(dw.body.*, indent + 2);
            print("  {s}cond:\n", .{indentStr});
            printExpression(dw.cond, indent + 2);
            print("{s})\n", .{indentStr});
        },
        .For => |f| {
            print("{s}{any}( {s}\n", .{ indentStr, @TypeOf(f), if (f.tag) |tag| tag else "null" });
            switch (f.init) {
                .Declaration => |decl| {
                    if (decl.VarDecl.init) |init| {
                        print("  {s}init:\n", .{indentStr});
                        printExpression(init, 6);
                    }
                },
                .Expression => |expr| {
                    if (expr != null) {
                        print("  {s}init:\n", .{indentStr});
                        printExpression(expr.?, indent + 4);
                    }
                },
            }
            if (f.cond) |cond| {
                print("  {s}cond:\n", .{indentStr});
                printExpression(cond, indent + 4);
            }
            if (f.post) |post| {
                print("  {s}post:\n", .{indentStr});
                printExpression(post, indent + 4);
            }
            print("  {s}body:\n", .{indentStr});
            printStatement(f.body.*, indent + 4);
        },
        .While => |w| {
            print("{s}{any}( {s}\n", .{ indentStr, @TypeOf(w), if (w.tag) |tag| tag else "null" });
            print("  {s}cond:\n", .{indentStr});
            printExpression(w.cond, indent + 4);
            print("  {s}body:\n", .{indentStr});
            printStatement(w.body.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Switch => |swtch| {
            print("{s}{any}( {s}\n", .{ indentStr, @TypeOf(swtch), if (swtch.tag) |tag| tag else "null" });
            print("  {s}cond:\n", .{indentStr});
            printExpression(swtch.cond, indent + 4);
            print("  {s}body:\n", .{indentStr});
            printStatement(swtch.body.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Case => |case| {
            print("{s}{any}( {s}\n", .{ indentStr, @TypeOf(case), if (case.tag) |tag| tag else "null" });
            if (case.cond) |cond| {
                print("  {s}cond:\n", .{indentStr});
                printExpression(cond, indent + 4);
            }
            if (case.body) |body| {
                print("  {s}body:\n", .{indentStr});
                printStatement(body.*, indent + 4);
                print("{s})\n", .{indentStr});
            }
        },
    }
}

fn printExpression(expr: Parser.Expression, indent: usize) void {
    const indentStr = std.heap.page_allocator.alloc(u8, indent) catch allocError();
    for (indentStr, 0..) |_, i| {
        indentStr[i] = ' ';
    }
    defer std.heap.page_allocator.free(indentStr);

    print("{s}{s}(", .{ indentStr, @tagName(expr) });
    switch (expr) {
        .Constant => print("{s})\n", .{expr.Constant}),
        .Var => print("{s})\n", .{expr.Var.name}),
        .Unary => |unary| {
            print("\n", .{});
            print("\n{s}  operation: {s}", .{ indentStr, @tagName(unary.operator) });
            print("\n{s}  factor:\n", .{indentStr});
            printExpression(unary.operand.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Binary => |binary| {
            print("\n", .{});
            print("{s}  left:\n", .{indentStr});
            printExpression(expr.Binary.left.*, indent + 4);
            print("{s}  operator: {s}\n", .{ indentStr, @tagName(binary.operator) });
            print("{s}  right:\n", .{indentStr});
            printExpression(expr.Binary.right.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Assignment => |assign| {
            print("\n", .{});
            std.debug.print("{s}  lhs:\n", .{indentStr});
            printExpression(assign.lhs.*, indent + 4);
            std.debug.print("{s}  rhs:\n", .{indentStr});
            printExpression(assign.rhs.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Ternary => |ternary| {
            print("\n", .{});
            std.debug.print("{s}  condition:\n", .{indentStr});
            printExpression(ternary.condition.*, indent + 4);
            std.debug.print("{s}  thenStmt:\n", .{indentStr});
            printExpression(ternary.thenStmt.*, indent + 4);
            std.debug.print("{s}  elseStmt:\n", .{indentStr});
            printExpression(ternary.elseStmt.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .FunctionCall => |funCall| {
            print("\n  {s}{s}(\n", .{ indentStr, funCall.name });
            for (funCall.args) |arg| {
                printExpression(arg, indent + 4);
            }
            print("  {s})\n", .{indentStr});
            print("{s})\n", .{indentStr});
        },
    }
}

pub fn printTAC(ir: TAC.Tacky) void {
    const program = ir;
    print("{any} (\n", .{@TypeOf(program)});
    for (program.functions) |function| {
        print("  {any} (\n", .{@TypeOf(function)});
        print("    name: {s}\n", .{function.name});
        print("    body:\n", .{});
        for (function.body.items) |instr| {
            print("      {s} (", .{@tagName(instr)});
            switch (instr) {
                .Unary => |unary| {
                    print("operator={any}, ", .{unary.operator});
                    switch (unary.src) {
                        .Constant => |src| print("src: {any}({s}), ", .{ @TypeOf(src), src }),
                        .Var => |src| print("src: {s}, ", .{src}),
                    }
                    switch (unary.dst) {
                        .Constant => |dst| print("src: {any}({s})", .{ @TypeOf(dst), dst }),
                        .Var => |dst| print("dst: {s}", .{dst}),
                    }
                    print(")\n", .{});
                },
                .Return => |ret| {
                    switch (ret.val) {
                        .Constant => |factor| print("val: {any}({s}))\n", .{ @TypeOf(factor), factor }),
                        .Var => |name| print("val: {s})\n", .{name}),
                    }
                },
                .Binary => |binary| {
                    print("operator={any}, ", .{binary.operator});
                    switch (binary.src1) {
                        .Constant => |src1| print("src1: {s} ", .{src1}),
                        .Var => |src1| print("src1: {s} ", .{src1}),
                    }
                    switch (binary.src2) {
                        .Constant => |src2| print("src2: {s} ", .{src2}),
                        .Var => |src2| print("src2: {s} ", .{src2}),
                    }
                    switch (binary.dst) {
                        .Constant => |dst| print("dst: {s}", .{dst}),
                        .Var => |dst| print("dst: {s}", .{dst}),
                    }
                    print(")\n", .{});
                },
                .Copy => |copy| {
                    switch (copy.src) {
                        .Constant => |src| print("src: {s} ", .{src}),
                        .Var => |src| print("src: {s} ", .{src}),
                    }
                    switch (copy.dst) {
                        .Constant => |dst| print("dst: {s}", .{dst}),
                        .Var => |dst| print("dst: {s}", .{dst}),
                    }
                    print(")\n", .{});
                },
                .Label => |label| {
                    print("name: {s})\n", .{label.identifier});
                },
                .Jump => |jump| {
                    print("label: {s})\n", .{jump.target});
                },
                .JumpIfZero => |jump| {
                    switch (jump.condition) {
                        .Constant => |cond| print("cond: {any}({s}) ", .{ @TypeOf(cond), cond }),
                        .Var => |cond| print("cond: {s} ", .{cond}),
                    }
                    print("label={s})\n", .{jump.target});
                },
                .JumpIfNotZero => |jump| {
                    switch (jump.condition) {
                        .Constant => |cond| print("cond: {any}({s}) ", .{ @TypeOf(cond), cond }),
                        .Var => |cond| print("cond: {s} ", .{cond}),
                    }
                    print("label: {s})\n", .{jump.target});
                },
            }
        }
        print("    )\n", .{});
        print("  )\n", .{});
    }
    print(")\n", .{});
}

pub fn printAssemblerAST(ast: Assembler.AST) void {
    const program = ast;
    print("{any} (\n", .{@TypeOf(program)});
    for (program.functions) |function| {
        print("  {any} (\n", .{@TypeOf(function)});
        print("    name={s}\n", .{function.name});
        print("    instructions=[\n", .{});

        for (function.instructions) |instr| {
            print("      {s} (", .{@tagName(instr)});
            switch (instr) {
                .Ret, .Cqo => {},
                .Mov => |mov| {
                    switch (mov.src) {
                        .Imm => |imm| print("src: Imm({s}) ", .{imm}),
                        .Pseudo => |reg| print("src: Pseudo({s}) ", .{reg}),
                        .Reg => |reg| print("src: Reg({s}) ", .{@tagName(reg)}),
                        .Stack => |stack| print("src: Stack({d}) ", .{stack}),
                    }
                    switch (mov.dst) {
                        .Imm => |imm| print("dst: Imm({s})", .{imm}),
                        .Pseudo => |reg| print("dst: Pseudo({s})", .{reg}),
                        .Reg => |reg| print("dst: Reg({s})", .{@tagName(reg)}),
                        .Stack => |stack| print("dst: Stack({d})", .{stack}),
                    }
                },
                .Unary => |unary| {
                    print("operator={s} ", .{@tagName(unary.operator)});
                    switch (unary.operand) {
                        .Imm => |imm| print("dst: Imm({s})", .{imm}),
                        .Pseudo => |reg| print("dst: Pseudo({s})", .{reg}),
                        .Reg => |reg| print("dst: Reg({s})", .{@tagName(reg)}),
                        .Stack => |stack| print("dst: Stack({d})", .{stack}),
                    }
                },
                .AllocStack => |allocStack| {
                    print("int: {d}", .{allocStack.stackPointer});
                },
                .Binary => |binary| {
                    print("operator: {s} ", .{@tagName(binary.operator)});
                    switch (binary.src) {
                        .Imm => |imm| print("src: Imm({s}) ", .{imm}),
                        .Pseudo => |reg| print("src: Pseudo({s}) ", .{reg}),
                        .Reg => |reg| print("src: Reg({s}) ", .{@tagName(reg)}),
                        .Stack => |stack| print("src: Stack({d}) ", .{stack}),
                    }
                    switch (binary.dst) {
                        .Imm => |imm| print("dst: Imm({s})", .{imm}),
                        .Pseudo => |reg| print("dst: Pseudo({s})", .{reg}),
                        .Reg => |reg| print("dst: Reg({s})", .{@tagName(reg)}),
                        .Stack => |stack| print("dst: Stack({d})", .{stack}),
                    }
                },
                .Idiv => |idiv| {
                    switch (idiv.operand) {
                        .Imm => |imm| print("src: Imm({s})", .{imm}),
                        .Pseudo => |reg| print("src: Pseudo({s})", .{reg}),
                        .Reg => |reg| print("src: Reg({s})", .{@tagName(reg)}),
                        .Stack => |stack| print("src: Stack({d})", .{stack}),
                    }
                },
                .Cmp => |cmp| {
                    std.debug.print("arg1: {any}, arg2: {any}", .{ cmp.arg1, cmp.arg2 });
                },
                .Jmp => |jmp| {
                    std.debug.print("target: {s}", .{jmp.target});
                },
                .JmpCC => |jmp| {
                    std.debug.print("condition: {s}, target: {s}", .{ @tagName(jmp.condition), jmp.target });
                },
                .SetCC => |set| {
                    switch (set.operand) {
                        .Imm => std.debug.print("condition: {s}, target: Imm({d})", .{ @tagName(set.condition), set.operand.Stack }),
                        .Pseudo => std.debug.print("condition: {s}, target: Pseudo({d})", .{ @tagName(set.condition), set.operand.Stack }),
                        .Reg => std.debug.print("condition: {s}, target: Reg({d})", .{ @tagName(set.condition), set.operand.Stack }),
                        .Stack => std.debug.print("condition: {s}, target: Stack({d})", .{ @tagName(set.condition), set.operand.Stack }),
                    }
                },
                .Label => |label| {
                    std.debug.print("id: {s}", .{label.id});
                },
            }
            print(")\n", .{});
        }

        print("    ]\n", .{});
        print("  )\n", .{});
    }
    print(")\n", .{});
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
