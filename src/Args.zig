const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const File = @import("File.zig");

const Args = @This();

pub const Stage = enum(usize) {
    Lex,
    Parse,
    Validate,
    TACky,
    CodeGen,
    ToSource,
    ToLibrary,
    ToExecutable,

    pub fn includes(self: Stage, other: Stage) bool {
        return @backingInt(self) >= @backingInt(other);
    }
};

allocator: Allocator,
debug: bool = false,
stage: Stage = .ToExecutable,
inputFiles: [][]const u8 = undefined,
outputELF: ?[]const u8 = null,

pub fn parse(allocator: Allocator, init: std.process.Init) Allocator.Error!Args {
    var args: Args = .{ .allocator = allocator };
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
            if (argsIt.next()) |outputELF| {
                args.outputELF = outputELF;
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

    if (args.outputELF == null) {
        const baseName = File.getBaseName(args.inputFiles[0]);
        args.outputELF = switch (args.stage) {
            .ToLibrary => try allocator.print("{s}.o", .{baseName}),
            else => try allocator.dupe(u8, baseName),
        };
    }

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

    process.exit(0);
}

pub fn deinit(self: Args, allocator: Allocator) void {
    allocator.free(self.inputFiles);
    allocator.free(self.outputELF.?);
}
