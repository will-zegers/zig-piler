const std = @import("std");
const print = std.debug.print;

const Parser = @import("Parser.zig");
const Semantic = @import("Semantic.zig");
const Symbol = Semantic.Symbol;
const Assembler = @import("Assembler.zig");
const TAC = @import("TAC.zig");
const Token = @import("Lexer.zig").Token;
const TokenIterator = Token.Iterator;

pub fn printLexerTokens(tokens: *TokenIterator) void {
    while (!tokens.eofReached()) {
        const token = tokens.next();
        std.debug.print("{any}: {s}\n", .{ token.type, token.symbol });
    }
}

pub fn printParserAST(tree: Parser.AST, symbolTable: ?Symbol.Table) void {
    const declarations = tree.declarations;
    print("{any}(\n", .{@TypeOf(tree)});
    for (declarations) |declaration| {
        printDeclaration(declaration, 4);
    }
    print("  )\n", .{});
    print(")\n", .{});

    if (symbolTable) |table| printSymbolTable(table);
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

    print("{s}{s} (", .{ indentStr, @tagName(decl) });
    switch (decl) {
        .VarDecl => |varDecl| {
            if (varDecl.storageClass) |sc| {
                print("{any} ", .{sc});
            }
            print("{s} {s}", .{ @tagName(varDecl.type), varDecl.name });
            if (varDecl.init) |init| {
                print("\n", .{});
                printExpression(init, indent + 2);
                print("{s})\n", .{indentStr});
            } else {
                print(")\n", .{});
            }
        },
        .FunDecl => |funDecl| {
            if (funDecl.storageClass) |sc| {
                print("{any} ", .{sc});
            }
            print("{s} {s}(", .{ @tagName(funDecl.type), funDecl.name });
            for (funDecl.params) |param| {
                print("{s} ", .{param.name});
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
            print("{s}{any}(", .{ indentStr, @TypeOf(case) });
            if (case.tag) |tag| print(" {s}", .{tag});
            print("\n", .{});
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

    print("{s}{s} (", .{ indentStr, @tagName(expr) });
    switch (expr) {
        .Assignment => |assign| {
            std.debug.print("{s}  lhs:\n", .{indentStr});
            printExpression(assign.lhs.*, indent + 4);
            std.debug.print("{s}  rhs:\n", .{indentStr});
            printExpression(assign.rhs.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Binary => |binary| {
            print("{s}  left:\n", .{indentStr});
            printExpression(expr.Binary.left.*, indent + 4);
            print("{s}  operator: {s}\n", .{ indentStr, @tagName(binary.operator) });
            print("{s}  right:\n", .{indentStr});
            printExpression(expr.Binary.right.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Cast => |cast| {
            print("( {s} ) ", .{@tagName(cast.target.type.?)});
            printExpression(cast.exp.*, 0);
        },
        .Constant => |constant| switch (constant) {
            .int => |int| print("int {d})\n", .{int}),
            .long => |long| print("long {d})\n", .{long}),
        },
        .FunctionCall => |funCall| {
            print("\n  {s}{s}(\n", .{ indentStr, funCall.name });
            for (funCall.args) |arg| {
                printExpression(arg, indent + 4);
            }
            print("  {s})\n", .{indentStr});
            print("{s})\n", .{indentStr});
        },
        .Ternary => |ternary| {
            std.debug.print("{s}  condition:\n", .{indentStr});
            printExpression(ternary.condition.*, indent + 4);
            std.debug.print("{s}  thenStmt:\n", .{indentStr});
            printExpression(ternary.thenStmt.*, indent + 4);
            std.debug.print("{s}  elseStmt:\n", .{indentStr});
            printExpression(ternary.elseStmt.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Unary => |unary| {
            print("\n{s}  operation: {s}", .{ indentStr, @tagName(unary.operator) });
            print("\n{s}  factor:\n", .{indentStr});
            printExpression(unary.operand.*, indent + 4);
            print("{s})\n", .{indentStr});
        },
        .Var => print("{s})\n", .{expr.Var.name}),
    }
}

fn printSymbolTable(symbolTable: Symbol.Table) void {
    std.debug.print("-------Symbol Table-------\n", .{});
    var it = symbolTable.iterator();
    while (it.next()) |entry| {
        const t = entry.value_ptr.*.type;
        const attrs = entry.value_ptr.*.attrs;
        std.debug.print("{s}:\n", .{entry.key_ptr.*});
        std.debug.print("  type: {s}\n", .{@tagName(t)});
        switch (t) {
            .FunType => {
                if (t.FunType.params.len > 0) {
                    std.debug.print("    params:", .{});
                    for (t.FunType.params) |param| {
                        std.debug.print(" {s}", .{@tagName(param.*)});
                    }
                    std.debug.print("\n", .{});
                }
                std.debug.print("    ret: {s}\n", .{@tagName(t.FunType.ret.*)});
            },
            .Int, .Long => {},
        }
        std.debug.print("  attrs: {s}\n", .{@tagName(attrs)});
        switch (attrs) {
            .Fun => |fun| {
                std.debug.print("  global: {any}\n", .{fun.global});
                std.debug.print("  defined: {any}\n", .{fun.defined});
            },
            .Static => |static| {
                std.debug.print("  global: {any}\n", .{static.global});
                std.debug.print("  initialValue:", .{});
                switch (static.initialValue) {
                    .Tentative, .None => std.debug.print("{any}\n", .{@tagName(static.initialValue)}),
                    .Initial => |init| switch (init) {
                        .int => |int| {
                            std.debug.print("{any}: {d}", .{ @tagName(static.initialValue), int });
                        },
                        .long => |long| {
                            std.debug.print("{any}: {d}", .{ @tagName(static.initialValue), long });
                        },
                    },
                }
            },
            .Local => {},
        }
    }
}

pub fn printTAC(ir: TAC.Program, symbolTable: Symbol.Table) void {
    const program = ir;
    print("{any} (\n", .{@TypeOf(program)});
    for (program.topLevel) |topLevel| {
        switch (topLevel) {
            .Function => printTACFunction(topLevel.Function),
            .StaticVariable => printTACStaticVariable(topLevel.StaticVariable),
        }
    }
    print(")\n", .{});
    printSymbolTable(symbolTable);
}

fn printTACFunction(function: TAC.Function) void {
    print("  {any} {s}(", .{ @TypeOf(function), function.name });
    if (function.params.len > 0) {
        std.debug.print("int {s}", .{function.params[0].name});
        for (1..function.params.len) |i| {
            std.debug.print(", int {s}", .{function.params[i].name});
        }
    }
    print(")\n", .{});
    // print("    name: {s}\n", .{function.name});
    print("    body:\n", .{});
    for (function.body) |instr| {
        print("      {s} (", .{@tagName(instr)});
        switch (instr) {
            .Binary => |binary| {
                print("operator={any}, ", .{binary.operator});
                printVal("src1: ", binary.src1, ", ");
                printVal("src2: ", binary.src2, ", ");
                printVal("dst: ", binary.dst, "");
                print(")\n", .{});
            },
            .Copy => |copy| {
                printVal("src: ", copy.src, ", ");
                printVal("dst: ", copy.dst, "");
                print(")\n", .{});
            },
            .FunCall => |funCall| {
                print("{s}(", .{funCall.name});
                if (funCall.args.len > 0) {
                    printVal("", funCall.args[0], "");
                    for (funCall.args) |arg| {
                        printVal(", ", arg, "");
                    }
                }
                std.debug.print(")", .{});
                print(" -> {s})\n", .{funCall.dst.Var});
            },
            .Label => |label| {
                print("name: {s})\n", .{label.identifier});
            },
            .Jump => |jump| {
                print("label: {s})\n", .{jump.target});
            },
            .JumpIfNotZero => |jump| {
                printVal("cond: ", jump.condition, ", ");
                print("label: {s})\n", .{jump.target});
            },
            .JumpIfZero => |jump| {
                printVal("cond: ", jump.condition, ", ");
                print("label: {s})\n", .{jump.target});
            },
            .Return => |ret| {
                printVal("val: ", ret.val, "");
                print(")\n", .{});
            },
            .SignExtend => |se| {
                printVal("src: ", se.src, ", ");
                printVal("dst: ", se.dst, "");
                print(")\n", .{});
            },
            .Truncate => |tr| {
                printVal("src: ", tr.src, ", ");
                printVal("dst: ", tr.dst, "");
                print(")\n", .{});
            },
            .Unary => |unary| {
                print("operator={any}, ", .{unary.operator});
                printVal("src: ", unary.src, ", ");
                printVal("dst: ", unary.dst, "");
                print(")\n", .{});
            },
        }
    }
    print("    )\n", .{});
    print("  )\n", .{});
}

fn printVal(prefix: []const u8, val: TAC.Val, suffix: []const u8) void {
    switch (val) {
        .Constant => switch (val.Constant) {
            .int => print("{s}int {d}{s}", .{ prefix, val.Constant.int, suffix }),
            .long => print("{s}long {d}{s}", .{ prefix, val.Constant.long, suffix }),
        },
        .Var => print("{s}{s}{s}", .{ prefix, val.Var, suffix }),
    }
}

fn printTACStaticVariable(staticVar: TAC.StaticVariable) void {
    print("  {any} {s} = {any} (global: {any})\n", .{ @TypeOf(staticVar), staticVar.identifier, staticVar.init, staticVar.global });
}

pub fn printAssemblerAST(ast: Assembler.Assembly) void {
    const program = ast;
    print("{any} (\n", .{@TypeOf(program)});
    for (program.topLevel) |topLevel| {
        switch (topLevel) {
            .Function => |function| {
                print("  {any} (\n", .{@TypeOf(function)});
                print("    name: {s}\n", .{function.name});
                print("    instructions: [\n", .{});

                for (function.instructions) |instr| {
                    printAssemblerFunction(instr);
                }
                print("    ]\n", .{});
                print("  )\n", .{});
            },
            .StaticVariable => |staticVar| {
                print("  {any} (\n", .{@TypeOf(staticVar)});
                print("    identifier: {s}\n", .{staticVar.name});
                print("    global: {any}\n", .{staticVar.global});
                switch (staticVar.init) {
                    .int => print("    int: {d}\n", .{staticVar.init.int}),
                    .long => print("    long: {d}\n", .{staticVar.init.long}),
                }
                print("  )\n", .{});
            },
        }
    }
    print(")\n", .{});
}

fn printAssemblerFunction(instr: Assembler.Instruction) void {
    print("      {s} (", .{@tagName(instr)});
    switch (instr) {
        .Binary => |binary| {
            print("operator: {s} ", .{@tagName(binary.operator)});
            printOperand("src: ", binary.src, ", ");
            printOperand("dst: ", binary.dst, null);
        },
        .Call => |call| print("name: {s}", .{call.identifier}),
        .Cmp => |cmp| {
            std.debug.print("arg1: {any}, arg2: {any}", .{ cmp.arg1, cmp.arg2 });
        },
        .Idiv => |idiv| {
            printOperand("src: ", idiv.operand, "");
        },
        .Jmp => |jmp| {
            std.debug.print("target: {s}", .{jmp.target});
        },
        .JmpCC => |jmp| {
            std.debug.print("condition: {s}, target: {s}", .{ @tagName(jmp.condition), jmp.target });
        },
        .Label => |label| {
            std.debug.print("id: {s}", .{label.id});
        },
        .Mov => |mov| {
            printType(mov.type);
            printOperand("src: ", mov.src, ", ");
            printOperand("dst: ", mov.dst, null);
        },
        .Push => |push| {
            printOperand("src: ", push.operand, null);
        },
        .Movsx => |movsx| {
            printOperand("src: ", movsx.src, ", ");
            printOperand("dst: ", movsx.dst, null);
        },
        .Ret, .Cdq => {},
        .SetCC => |set| {
            std.debug.print("condition: {s}, ", .{@tagName(set.condition)});
            printOperand("target: ", set.operand, null);
        },
        .Unary => |unary| {
            print("operator: {s} ", .{@tagName(unary.operator)});
            printOperand("dst: ", unary.operand, null);
        },
    }
    print(")\n", .{});
}

fn printOperand(prefix: ?[]const u8, operand: Assembler.Operand, suffix: ?[]const u8) void {
    if (prefix) |p| print("{s}", .{p});
    switch (operand) {
        .Imm => print("Imm({d})", .{operand.Imm}),
        .Pseudo => print("Pseudo({s})", .{operand.Pseudo}),
        .Reg => print("Reg({s})", .{@tagName(operand.Reg)}),
        .Stack => print("Stack({d})", .{operand.Stack}),
        .Data => print("Data({s}) ", .{operand.Data}),
    }
    if (suffix) |s| print("{s}", .{s});
}

fn printType(t: Assembler.Type) void {
    print("type: ", .{});
    switch (t) {
        .Long => print("long, ", .{}),
        .Quad => print("quad, ", .{}),
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
