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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    var inputFile: []const u8 = "";
    var debug = false;

    var stage: Stage = .ToExecutable;
    _ = args.skip(); // skip the executable name
    while (args.next()) |arg| {
        if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg))
            usage()
        else if (mem.eql(u8, "-d", arg) or mem.eql(u8, "--debug", arg))
            debug = true
        else if (mem.eql(u8, "--lex", arg))
            stage = .Lex
        else if (mem.eql(u8, "--parse", arg))
            stage = .Parse
        else if (mem.eql(u8, "--validate", arg))
            stage = .Validate
        else if (mem.eql(u8, "--tacky", arg))
            stage = .TACky
        else if (mem.eql(u8, "--codegen", arg))
            stage = .CodeGen
        else if (mem.eql(u8, "-S", arg))
            stage = .ToSource
        else if (mem.eql(u8, "-c", arg))
            stage = .ToLibrary
        else if (mem.eql(u8, "-e", arg))
            stage = .ToExecutable
        else
            inputFile = arg;
    }

    if (inputFile.len == 0) usage();
    std.Io.Dir.cwd().access(init.io, inputFile, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("{s}: No such file or directory", .{inputFile});
            std.process.exit(1);
        },
        else => return e,
    };

    const outputBinary: []const u8 = try getOutputBinary(allocator, inputFile);
    defer allocator.free(outputBinary);

    const outputSource = try allocator.print("{s}.s", .{outputBinary});
    defer allocator.free(outputSource);

    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, inputFile, allocator, .unlimited);
    const textZ = try allocator.dupeSentinel(u8, text, 0);
    defer allocator.free(textZ);
    allocator.free(text);

    var list: std.ArrayList([]const u8) = .empty;

    var it = std.mem.splitScalar(u8, textZ, '\n');
    while (it.next()) |line| {
        try list.append(allocator, line);
    }
    const lines = try list.toOwnedSlice(allocator);
    defer allocator.free(lines);

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

        tokens = try lexer.tokenize(textZ);

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
        var semantic = Semantic.init(allocator);
        defer semantic.deinit();

        semantic.resolve(&ast);
        semantic.reportAnyErrors(lines);

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
        std.log.info("Writing source to '{s}'", .{outputSource});
        var ce = try CodeEmitter.init(allocator, assembly);
        defer ce.deinit();
        try ce.writeToFile(init.io, outputSource);
    } else return;

    if (stage.includes(.ToExecutable) or stage.includes(.ToLibrary)) {
        var cmd = if (stage == .ToLibrary)
            try std.process.spawn(init.io, .{ .argv = &.{ "gcc", "-c", outputSource, "-o", outputBinary } })
        else
            try std.process.spawn(init.io, .{ .argv = &.{ "gcc", outputSource, "-o", outputBinary } });

        const status = try cmd.wait(init.io);
        if (status.exited != 0) {
            std.log.err("Failed to compile {s}", .{outputBinary});
            std.process.exit(status.exited);
        } else {
            std.log.info("'{s}' successfully compiled!", .{outputBinary});
        }
    }
}

fn getOutputBinary(allocator: std.mem.Allocator, inputFile: []const u8) ![]const u8 {
    var outputBinary = inputFile;
    for (1..inputFile.len + 1) |i| {
        const backIndex = inputFile.len - i;
        if (inputFile[backIndex] == '.') {
            outputBinary = inputFile[0..backIndex];
            break;
        }
    }
    return try allocator.print("{s}", .{outputBinary});
}
