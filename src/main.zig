const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const File = @import("File.zig");
const Args = @import("Args.zig");
const Symbol = @import("Semantic/Symbols.zig");

const Debugger = @import("Debugger.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Semantic = @import("Semantic.zig");
const TAC = @import("TAC.zig");
const Assembler = @import("Assembler.zig");
const CodeEmitter = @import("CodeEmitter.zig");

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;

    const args = try Args.parse(allocator, init);
    const debug = args.debug;
    const stage = args.stage;
    defer args.deinit(allocator);

    var sourceList: ArrayList([]const u8) = .empty;
    defer {
        for (sourceList.items) |item| {
            allocator.free(item);
        }
        sourceList.deinit(allocator);
    }

    for (args.inputFiles) |inputFile| {
        // Only run translation units (C source files) through the compiler
        if (isTranslationUnit(init.io, inputFile)) |res| {
            if (!res) {
                try sourceList.append(allocator, try allocator.dupe(u8, inputFile));
                continue;
            }
        } else |e| return e;

        const file = try File.process(allocator, init.io, inputFile);
        defer file.deinit();

        try sourceList.append(allocator, try allocator.dupe(u8, file.outputSrc));

        var tokens: Lexer.Token.Iterator = undefined;
        if (stage.includes(.Lex)) {
            log.info("Running lexer...", .{});
            var lexer = try Lexer.init(allocator);
            defer lexer.deinit();

            tokens = try lexer.tokenize(file.text);

            if (debug) {
                std.debug.print("-------tokens-------\n", .{});
                Debugger.printLexerTokens(&tokens);
                tokens.reset();
            }
        } else return;
        defer tokens.deinit();

        var tree: Parser.AST = undefined;
        if (stage.includes(.Parse)) {
            log.info("Running parser...", .{});
            tree = try Parser.parse(allocator, &tokens, file.lines);

            if (debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(tree, null);
            }
        } else return;
        defer tree.deinit(allocator);

        var symbolTable: Symbol.Table = undefined;
        if (stage.includes(.Validate)) {
            log.info("Running semantic analysis...", .{});
            symbolTable = Semantic.run(allocator, &tree, file.lines);

            if (debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(tree, symbolTable);
            }
        } else return;
        defer symbolTable.deinit();

        var tac: TAC.Program = undefined;
        if (stage.includes(.TACky)) {
            log.info("Generating Tacky...", .{});
            tac = TAC.emit(allocator, &symbolTable, tree);

            if (debug) {
                std.debug.print("-------TAC-------\n", .{});
                Debugger.printTAC(tac, symbolTable);
            }
        } else return;
        defer tac.deinit();

        var assembly: Assembler.Assembly = undefined;
        if (stage.includes(.CodeGen)) {
            log.info("Running assembler...", .{});
            assembly = try Assembler.assemble(allocator, symbolTable, tac);

            if (debug) {
                std.debug.print("------generated-------\n", .{});
                Debugger.printAssemblerAST(assembly);
            }
        } else return;
        defer assembly.deinit();

        if (stage.includes(.ToSource)) {
            log.info("Writing source to '{s}'", .{file.outputSrc});
            var ce = try CodeEmitter.init(allocator, assembly);
            defer ce.deinit();
            try ce.writeToFile(allocator, init.io, file.outputSrc);
        } else return;
    }

    if (stage.includes(.ToExecutable) or stage.includes(.ToLibrary)) {
        var argv: ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        try argv.appendSlice(allocator, &.{ "gcc", "-o", args.outputELF.? });
        try argv.appendSlice(allocator, sourceList.items);
        if (stage == .ToLibrary) {
            try argv.append(allocator, "-c");
        }
        for (args.libraries) |lib| {
            try argv.append(allocator, lib);
        }

        var cmd = try process.spawn(init.io, .{ .argv = argv.items });
        const status = try cmd.wait(init.io);
        if (status.exited != 0) {
            log.err("Failed to compile {s}", .{args.outputELF.?});
            process.exit(status.exited);
        } else {
            log.info("'{s}' successfully compiled!", .{args.outputELF.?});
        }
    }
}

fn isTranslationUnit(io: Io, filePath: []const u8) !bool {
    if (mem.endsWith(u8, filePath, ".s")) { // check if file as an assembler source extension
        log.info("Ignoring assembler source file {s}", .{filePath});
        return false;
    }

    var magicNumber: [4]u8 = undefined;
    _ = try Io.Dir.cwd().readFile(io, filePath, &magicNumber);

    if (mem.eql(u8, "\x7fELF", &magicNumber)) { // check that it's not an ELF (namely, not a '.o')
        log.info("Ignoring ELF file {s}", .{filePath});
        return false;
    }

    return true;
}
