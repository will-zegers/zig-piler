const std = @import("std");
const mem = std.mem;
const Lexer = @import("Lexer.zig");
const regex = @import("regex");
const Parser = @import("Parser.zig");
const Assembler = @import("Assembler.zig");
const TokenIterator = @import("token.zig").TokenIterator;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var lex = false;
    var parse = false;
    var codegen = false;
    var inputFile: [:0]const u8 = undefined;
    _ = args.skip(); // skip the executable name
    while (args.next()) |arg| {
        if (mem.eql(u8, "--lex", arg)) {
            lex = true;
        } else if (mem.eql(u8, "--parse", arg)) {
            parse = true;
        } else if (mem.eql(u8, "--codegen", arg)) {
            codegen = true;
        } else {
            inputFile = arg;
        }
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    const textZ = try init.gpa.dupeSentinel(u8, text, 0);
    defer init.gpa.free(textZ);
    init.gpa.free(text);

    if (codegen or parse or lex) {
        std.log.info("Running lexer...", .{});
        var lexer = try Lexer.init(init.gpa);
        defer lexer.deinit();

        const tokens = try lexer.tokenize(textZ);

        if (codegen or parse) {
            std.log.info("Running parser...", .{});
            const ast = Parser.parse(tokens);
            std.debug.print("-------parsed-------\n", .{});
            ast.print();

            if (codegen) {
                std.log.info("Running assembler...", .{});
                var generated = Assembler.codeGen(init.gpa, ast);
                defer generated.deinit();
                std.debug.print("------generated-------\n", .{});
                generated.print();
            }
        }
    }
}
