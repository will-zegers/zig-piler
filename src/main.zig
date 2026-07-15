const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const CodeEmitter = @import("CodeEmitter.zig");
const Debugger = @import("Debugger.zig");
const TAC = @import("TAC.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var inputFile: ?[]const u8 = null;
    var outputFile: []const u8 = "out.asm";
    var debug = false;

    var lex: bool = false;
    var parse: bool = false;
    var tacky: bool = false;
    var codegen: bool = true;
    _ = args.skip(); // skip the executable name
    while (args.next()) |arg| {
        if (mem.eql(u8, "-o", arg)) {
            outputFile = args.next() orelse {
                std.log.err("missing file name after -o", .{});
                std.process.exit(0);
            };
        } else if (mem.eql(u8, "--lex", arg)) {
            lex = true;
            codegen = false;
        } else if (mem.eql(u8, "--parse", arg)) {
            parse = true;
            codegen = false;
        } else if (mem.eql(u8, "--tacky", arg)) {
            tacky = true;
            codegen = false;
        } else if (mem.eql(u8, "--debug", arg)) {
            debug = true;
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
        , .{});
        std.process.exit(0);
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, inputFile.?, init.gpa, .unlimited);
    const textZ = try init.gpa.dupeSentinel(u8, text, 0);
    defer init.gpa.free(textZ);
    init.gpa.free(text);

    if (lex or parse or tacky or codegen) {
        std.log.info("Running lexer...", .{});
        var lexer = try Lexer.init(init.gpa);
        defer lexer.deinit();

        const tokens = try lexer.tokenize(textZ);
        if (lex and debug) {
            std.debug.print("-------tokens-------\n", .{});
            Debugger.printLexerTokens(tokens);
        }

        if (parse or tacky or codegen) {
            std.log.info("Running parser...", .{});
            var ast = Parser.parse(init.gpa, tokens);
            defer ast.deinit();

            if (parse and debug) {
                std.debug.print("-------parsed-------\n", .{});
                Debugger.printParserAST(ast);
            }

            if (tacky or codegen) {
                std.log.info("Generating Tacky...", .{});
                var tac = TAC.init(init.gpa, ast);
                defer tac.function.deinit();

                if (tacky and debug) {
                    std.debug.print("-------TAC-------\n", .{});
                    Debugger.printTAC(tac);
                }

                if (codegen) {
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
            }
        }
    }
}
