const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const TAC = @import("TAC.zig");
const Assembler = @import("Assembler.zig");
const CodeEmitter = @import("CodeEmitter.zig");
const Debugger = @import("Debugger.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var inputFile: ?[]const u8 = null;
    var debug = false;

    var lex: bool = false;
    var parse: bool = false;
    var tacky: bool = false;
    var codegen: bool = false;
    var all: bool = true; // run all by default
    var compile = true;
    _ = args.skip(); // skip the executable name
    while (args.next()) |arg| {
        if (mem.eql(u8, "--lex", arg)) {
            lex = true;
            all = false;
        } else if (mem.eql(u8, "--parse", arg)) {
            parse = true;
            all = false;
        } else if (mem.eql(u8, "--tacky", arg)) {
            tacky = true;
            all = false;
        } else if (mem.eql(u8, "--codegen", arg)) {
            codegen = true;
            all = false;
        } else if (mem.eql(u8, "--debug", arg)) {
            debug = true;
        } else if (mem.eql(u8, "-S", arg)) {
            compile = false;
        } else {
            inputFile = arg;
        }
    }
    if (inputFile == null) {
        std.log.info(
            \\usage: zig-piler [options] file
            \\        --lex        Run only the lexer
            \\        --parse      Run the lexer and parser
            \\        --tacky      Run the lexer, parser, and generate intermediate representation
            \\        --codegen    Run all stages and generate an output file [default]
            \\        -o <file>    Place the output into <file>
            \\        -S           Produce only the source file, don't compile
        , .{});
        std.process.exit(0);
    }
    const outputBinary: []const u8 = try getOutputBinary(init.gpa, inputFile.?);
    defer init.gpa.free(outputBinary);
    const outputSource = try std.fmt.allocPrint(init.gpa, "{s}.s", .{outputBinary});
    defer init.gpa.free(outputSource);

    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, inputFile.?, init.gpa, .unlimited);
    const textZ = try init.gpa.dupeSentinel(u8, text, 0);
    defer init.gpa.free(textZ);
    init.gpa.free(text);

    if (all or lex or parse or tacky or codegen) {
        std.log.info("Running lexer...", .{});
        var lexer = try Lexer.init(init.gpa);
        defer lexer.deinit();

        const tokens = try lexer.tokenize(textZ);
        if (lex and debug) {
            std.debug.print("-------tokens-------\n", .{});
            Debugger.printLexerTokens(tokens);
        }

        if (all or parse or tacky or codegen) {
            std.log.info("Running parser...", .{});
            var ast = Parser.parse(init.gpa, tokens);
            defer ast.deinit();

            if (parse and debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(ast);
            }

            if (all or tacky or codegen) {
                std.log.info("Generating Tacky...", .{});
                var tac = TAC.init(init.gpa, ast);
                defer tac.function.deinit();

                if (tacky and debug) {
                    std.debug.print("-------TAC-------\n", .{});
                    Debugger.printTAC(tac);
                }

                if (all or codegen) {
                    std.log.info("Running assembler...", .{});
                    var assembly = Assembler.codeGen(init.gpa, tac);
                    defer assembly.deinit();

                    if (debug) {
                        std.debug.print("------generated-------\n", .{});
                        Debugger.printAssemblerAST(assembly);
                    }

                    if (all) {
                        std.log.info("Writing source to '{s}'", .{outputSource});
                        var ce = try CodeEmitter.init(init.gpa, assembly);
                        defer ce.deinit();
                        try ce.writeToFile(init.io, outputSource);

                        if (compile) {
                            var cmd = try std.process.spawn(init.io, .{ .argv = &.{ "gcc", outputSource, "-o", outputBinary } });
                            const status = try cmd.wait(init.io);
                            if (status.exited != 0) {
                                std.process.fatal("Failed to compile {s}", .{outputBinary});
                                std.process.exit(status.exited);
                            } else {
                                std.log.info("'{s}' successfully compiled!", .{outputBinary});
                            }
                        }
                    }
                }
            }
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
    return try std.fmt.allocPrint(allocator, "{s}", .{outputBinary});
}
