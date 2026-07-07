const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Lexer = @import("Lexer.zig");
const regex = @import("regex");
const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const CodeEmitter = @import("CodeEmitter.zig");
const TokenIterator = @import("token.zig").TokenIterator;
const Debugger = @import("Debugger.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var inputFile: ?[]const u8 = null;
    var outputFile: []const u8 = "out.asm";
    var debug = false;

    _ = args.skip(); // skip the executable name
    while (args.next()) |arg| {
        if (mem.eql(u8, "-o", arg)) {
            outputFile = args.next() orelse {
                std.log.err("missing file name after -o", .{});
                std.process.exit(0);
            };
        } else if (mem.eql(u8, "--debug", arg)) {
            debug = true;
        } else {
            inputFile = arg;
        }
    }
    if (inputFile == null) {
        std.log.info(
            \\usage: zig-piler [options] file
            \\        -o <file>    Place the output into <file>
        , .{});
        std.process.exit(0);
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, inputFile.?, init.gpa, .unlimited);
    const textZ = try init.gpa.dupeSentinel(u8, text, 0);
    defer init.gpa.free(textZ);
    init.gpa.free(text);

    std.log.info("Running lexer...", .{});
    var lexer = try Lexer.init(init.gpa);
    defer lexer.deinit();

    const tokens = try lexer.tokenize(textZ);

    std.log.info("Running parser...", .{});
    const ast = Parser.parse(tokens);
    if (debug) {
        std.debug.print("-------parsed-------\n", .{});
        Debugger.printParserAST(ast);
    }

    std.log.info("Running assembler...", .{});
    var assembly = Assembler.codeGen(init.gpa, ast);
    defer assembly.deinit();
    if (debug) {
        std.debug.print("------generated-------\n", .{});
        Debugger.printAssemblerAST(assembly);
    }

    std.log.info("Writing code to './{s}'", .{outputFile});
    var ce = try CodeEmitter.init(init.gpa, assembly);
    defer ce.deinit();
    try ce.writeToFile(init.io, "out.asm");
}
