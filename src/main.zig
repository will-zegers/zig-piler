const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const File = @import("File.zig");
const Args = @import("Args.zig");

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
        var ast: Parser.AST = undefined;
        var tac: TAC.Program = undefined;
        var assembly: Assembler.Assembly = undefined;
        defer {
            if (stage.includes(.Lex)) tokens.deinit();
            if (stage.includes(.Parse)) ast.deinit(allocator);
            if (stage.includes(.TACky)) tac.deinit();
            if (stage.includes(.CodeGen)) assembly.deinit();
        }

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

        if (stage.includes(.Parse)) {
            log.info("Running parser...", .{});
            ast = Parser.parse(allocator, &tokens) catch {
                const index = tokens.lineIndex;
                log.err(" {d} | {s}\n", .{ index + 1, file.lines[index] });
                process.exit(1);
            };

            if (debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(ast);
            }
        } else return;

        if (stage.includes(.Validate)) {
            log.info("Running semantic analysis...", .{});
            // var semantic = Semantic.init(allocator, file.lines);

            Semantic.run(allocator, &ast, file.lines);

            if (debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(ast);
            }
        } else return;

        if (stage.includes(.TACky)) {
            log.info("Generating Tacky...", .{});
            tac = TAC.emit(allocator, ast);

            if (debug) {
                std.debug.print("-------TAC-------\n", .{});
                Debugger.printTAC(tac);
            }
        } else return;

        if (stage.includes(.CodeGen)) {
            log.info("Running assembler...", .{});
            assembly = Assembler.assemble(allocator, tac);

            if (debug) {
                std.debug.print("------generated-------\n", .{});
                Debugger.printAssemblerAST(assembly);
            }
        } else return;

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
        if (stage == .ToLibrary) {
            try argv.append(allocator, "-c");
        }
        try argv.appendSlice(allocator, sourceList.items);

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
