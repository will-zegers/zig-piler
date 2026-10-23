const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const Debugger = @import("Debugger.zig");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Semantic = @import("Semantic.zig");
const TAC = @import("TAC.zig");
const Assembler = @import("Assembler.zig");
const CodeEmitter = @import("CodeEmitter.zig");

const Stage = enum(usize) {
    Lex,
    Parse,
    Validate,
    TACky,
    CodeGen,
    ToSource,
    ToLibrary,
    ToExecutable,

    fn includes(self: Stage, other: Stage) bool {
        return @backingInt(self) >= @backingInt(other);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try processArgs(allocator, init);
    const debug = args.debug;
    const stage = args.stage;
    const outputBin = args.outputBin;
    const inputFiles = args.inputFiles;
    defer allocator.free(inputFiles);

    var sourceList: ArrayList([]const u8) = .empty;
    defer {
        for (sourceList.items) |item| {
            allocator.free(item);
        }
        sourceList.deinit(allocator);
    }

    for (inputFiles) |inputFile| {
        const files = try processFiles(allocator, init.io, inputFile);
        defer files.deinit(allocator);

        const text = files.text;
        const lines = files.lines;
        const outputSrc = files.outputSrc;

        if (isELF(text)) continue; // only process text files (i.e. non-executables)

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
            std.log.info("Running lexer...", .{});
            var lexer = try Lexer.init(allocator);
            defer lexer.deinit();

            tokens = try lexer.tokenize(text);

            if (debug) {
                std.debug.print("-------tokens-------\n", .{});
                Debugger.printLexerTokens(&tokens);
                tokens.reset();
            }
        } else return;

        if (stage.includes(.Parse)) {
            std.log.info("Running parser...", .{});
            ast = Parser.parse(allocator, &tokens) catch {
                const index = tokens.lineIndex;
                std.log.err(" {d} | {s}\n", .{ index + 1, lines[index] });
                std.process.exit(1);
            };

            if (debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(ast);
            }
        } else return;

        if (stage.includes(.Validate)) {
            std.log.info("Running semantic analysis...", .{});
            // var semantic = Semantic.init(allocator, lines);

            Semantic.run(allocator, &ast, lines);

            if (debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(ast);
            }
        } else return;

        if (stage.includes(.TACky)) {
            std.log.info("Generating Tacky...", .{});
            tac = TAC.emit(allocator, ast);

            if (debug) {
                std.debug.print("-------TAC-------\n", .{});
                Debugger.printTAC(tac);
            }
        } else return;

        if (stage.includes(.CodeGen)) {
            std.log.info("Running assembler...", .{});
            assembly = Assembler.assemble(allocator, tac);

            if (debug) {
                std.debug.print("------generated-------\n", .{});
                Debugger.printAssemblerAST(assembly);
            }
        } else return;

        if (stage.includes(.ToSource)) {
            std.log.info("Writing source to '{s}'", .{outputSrc});
            var ce = try CodeEmitter.init(allocator, assembly);
            defer ce.deinit();
            try ce.writeToFile(allocator, init.io, outputSrc);
        } else return;

        try sourceList.append(allocator, try allocator.dupe(u8, outputSrc));
    }
    const sourceFiles = try mem.join(allocator, " ", sourceList.items);
    defer allocator.free(sourceFiles);

    if (stage.includes(.ToExecutable) or stage.includes(.ToLibrary)) {
        var cmd = if (stage == .ToLibrary)
            try std.process.spawn(init.io, .{ .argv = &.{ "gcc", "-c", sourceFiles, "-o", outputBin } })
        else
            try std.process.spawn(init.io, .{ .argv = &.{ "gcc", sourceFiles, "-o", outputBin } });

        const status = try cmd.wait(init.io);
        if (status.exited != 0) {
            std.log.err("Failed to compile {s}", .{outputBin});
            std.process.exit(status.exited);
        } else {
            std.log.info("'{s}' successfully compiled!", .{outputBin});
        }
    }
}

const Args = struct {
    debug: bool = false,
    stage: Stage = .ToExecutable,
    inputFiles: [][]const u8 = undefined,
    outputBin: []const u8 = "a.out",
};

fn processArgs(allocator: Allocator, init: std.process.Init) Allocator.Error!Args {
    var args: Args = .{};
    var inputFiles: ArrayList([]const u8) = .empty;

    var argsIt = try init.minimal.args.iterateAllocator(init.gpa);
    defer argsIt.deinit();

    _ = argsIt.skip(); // skip the executable name
    while (argsIt.next()) |arg| {
        if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg))
            usage()
        else if (mem.eql(u8, "-d", arg) or mem.eql(u8, "--debug", arg))
            args.debug = true
        else if (mem.eql(u8, "-o", arg)) {
            if (argsIt.next()) |outputBin| {
                args.outputBin = outputBin;
            } else {
                usage();
            }
        } else if (mem.eql(u8, "--lex", arg))
            args.stage = .Lex
        else if (mem.eql(u8, "--parse", arg))
            args.stage = .Parse
        else if (mem.eql(u8, "--validate", arg))
            args.stage = .Validate
        else if (mem.eql(u8, "--tacky", arg))
            args.stage = .TACky
        else if (mem.eql(u8, "--codegen", arg))
            args.stage = .CodeGen
        else if (mem.eql(u8, "-S", arg))
            args.stage = .ToSource
        else if (mem.eql(u8, "-c", arg))
            args.stage = .ToLibrary
        else if (mem.eql(u8, "-e", arg))
            args.stage = .ToExecutable
        else
            try inputFiles.append(allocator, arg);
    }
    args.inputFiles = try inputFiles.toOwnedSlice(allocator);

    if (args.inputFiles.len == 0) usage();

    return args;
}

fn usage() noreturn {
    std.log.info(
        \\usage: zig-piler [options] file
        \\        -h, --help    Print this help message
        \\        -d, --debug   Output debug information
        \\        -o <file>     Place the output into <file>
        \\  Only one of the following flags should be used to specify where the compiler
        \\  should stop. Otherwise, it will use the last flag given in the command
        \\        --lex         Tokenize the input
        \\        --parse       Parse input tokens (no semantic analysis)
        \\        --validate    Parse with semantic analysis
        \\        --tacky       Generate intermediate representation
        \\        --codegen     Generate output from the assembler
        \\        -S            Produce only the source file, don't compile
        \\        -c            Run all stages and compile to .o library
        \\        -e            (default) Run all stages and compile to executable
    , .{});

    std.process.exit(0);
}

fn isELF(contents: []const u8) bool {
    if (contents[0] == 0x7f and mem.eql(u8, "ELF", contents[1..4])) {
        return true;
    }
    return false;
}

const Files = struct {
    text: [:0]const u8,
    lines: [][]const u8,
    outputSrc: []const u8,

    pub fn deinit(self: Files, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.lines);
        allocator.free(self.outputSrc);
    }
};

/// Based on the provided input file, gather up all the necessary input (text
/// that will be fed to the lexer, a list of file lines for error reporting)
/// and names for output files (binary and source .s files)
fn processFiles(
    allocator: Allocator,
    io: std.Io,
    inputFile: []const u8,
) !Files {
    const rawText = try std.Io.Dir.cwd().readFileAlloc(io, inputFile, allocator, .unlimited);
    defer allocator.free(rawText);

    const text = try allocator.dupeSentinel(u8, rawText, 0);

    const outputSrc: []const u8 = try getSourceName(allocator, inputFile);

    var it = mem.splitScalar(u8, text, '\n');
    var list: ArrayList([]const u8) = .empty;
    while (it.next()) |line| {
        try list.append(allocator, line);
    }
    const lines = try list.toOwnedSlice(allocator);

    return .{ .text = text, .lines = lines, .outputSrc = outputSrc };
}

/// Based on the input file name, generate an output source name based on the last
/// position of '.' (e.g. compiled output for "myprogram.c" will be "myprogram")
fn getSourceName(allocator: Allocator, inputFile: []const u8) ![]const u8 {
    var outputBin = inputFile;
    for (1..inputFile.len + 1) |i| {
        const backIndex = inputFile.len - i;
        if (inputFile[backIndex] == '.') {
            outputBin = inputFile[0..backIndex];
            break;
        }
    }
    return try allocator.print("{s}.s", .{outputBin});
}
