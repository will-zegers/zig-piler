const std = @import("std");
const Io = std.Io;
const mem = std.mem;

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
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = processArgs(init);
    const debug = args.debug;
    const stage = args.stage;
    const inputFile = args.inputFile;

    const files = try processFiles(allocator, init.io, inputFile);
    defer files.deinit(allocator);
    const text = files.text;
    const lines = files.lines;
    const outputSrc = files.outputSrc;
    const outputBin = files.outputBin;

    var tokens: Lexer.Token.Iterator = undefined;
    var ast: Parser.AST = undefined;
    var tac: TAC.Tacky = undefined;
    var assembly: Assembler.AST = undefined;
    defer {
        if (stage.includes(.Lex)) tokens.deinit();
        if (stage.includes(.Parse)) ast.deinit();
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
        var semantic = Semantic.init(allocator, lines);
        defer semantic.deinit();

        semantic.resolve(&ast);

        if (debug) {
            std.debug.print("-------parsed-------\n", .{});
            Debugger.printParserAST(ast);
        }
    } else return;

    if (stage.includes(.TACky)) {
        std.log.info("Generating Tacky...", .{});
        tac = TAC.init(allocator, ast);

        if (debug) {
            std.debug.print("-------TAC-------\n", .{});
            Debugger.printTAC(tac);
        }
    } else return;

    if (stage.includes(.CodeGen)) {
        std.log.info("Running assembler...", .{});
        assembly = Assembler.codeGen(allocator, tac);

        if (debug) {
            std.debug.print("------generated-------\n", .{});
            Debugger.printAssemblerAST(assembly);
        }
    } else return;

    if (stage.includes(.ToSource)) {
        std.log.info("Writing source to '{s}'", .{outputSrc});
        var ce = try CodeEmitter.init(allocator, assembly);
        defer ce.deinit();
        try ce.writeToFile(init.io, outputSrc);
    } else return;

    if (stage.includes(.ToExecutable) or stage.includes(.ToLibrary)) {
        var cmd = if (stage == .ToLibrary)
            try std.process.spawn(init.io, .{ .argv = &.{ "gcc", "-c", outputSrc, "-o", outputBin } })
        else
            try std.process.spawn(init.io, .{ .argv = &.{ "gcc", outputSrc, "-o", outputBin } });

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
    inputFile: []const u8 = "",
};

fn processArgs(init: std.process.Init) Args {
    var args: Args = .{};

    var argsIt = try init.minimal.args.iterateAllocator(init.gpa);
    defer argsIt.deinit();

    _ = argsIt.skip(); // skip the executable name
    while (argsIt.next()) |arg| {
        if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg))
            usage()
        else if (mem.eql(u8, "-d", arg) or mem.eql(u8, "--debug", arg))
            args.debug = true
        else if (mem.eql(u8, "--lex", arg))
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
            args.inputFile = arg;
    }

    if (args.inputFile.len == 0) usage();

    return args;
}

fn usage() noreturn {
    std.log.info(
        \\usage: zig-piler [options] file
        \\        -h, --help    Print this help message
        \\        -d, --debug   Output debug information
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

const Files = struct {
    text: [:0]const u8,
    lines: [][]const u8,
    outputSrc: []const u8,
    outputBin: []const u8,

    pub fn deinit(self: Files, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.lines);
        allocator.free(self.outputSrc);
        allocator.free(self.outputBin);
    }
};

/// Based on the provided input file, gather up all the necessary input (text
/// that will be fed to the lexer, a list of file lines for error reporting)
/// and names for output files (binary and source .s files)
fn processFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputFile: []const u8,
) !Files {
    const rawText = try std.Io.Dir.cwd().readFileAlloc(io, inputFile, allocator, .unlimited);
    defer allocator.free(rawText);

    const text = try allocator.dupeSentinel(u8, rawText, 0);

    const outputBin: []const u8 = try getOutputBinary(allocator, inputFile);
    const outputSrc = try allocator.print("{s}.s", .{outputBin});

    var it = std.mem.splitScalar(u8, text, '\n');
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |line| {
        try list.append(allocator, line);
    }
    const lines = try list.toOwnedSlice(allocator);

    return .{ .text = text, .lines = lines, .outputSrc = outputSrc, .outputBin = outputBin };
}

/// Based on the input file name, generate an output binary name based on the last
/// position of '.' (e.g. compiled output for "myprogram.c" will be "myprogram")
fn getOutputBinary(allocator: std.mem.Allocator, inputFile: []const u8) ![]const u8 {
    var outputBin = inputFile;
    for (1..inputFile.len + 1) |i| {
        const backIndex = inputFile.len - i;
        if (inputFile[backIndex] == '.') {
            outputBin = inputFile[0..backIndex];
            break;
        }
    }
    return try allocator.print("{s}", .{outputBin});
}
