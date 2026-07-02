const std = @import("std");
const mem = std.mem;
const Lexer = @import("Lexer.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var runLexer = false;
    var inputFile: [:0]const u8 = undefined;
    _ = args.skip(); // skip the executable name
    while (args.next()) |arg| {
        if (mem.eql(u8, "--lex", arg)) {
            runLexer = true;
        } else {
            inputFile = arg;
        }
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    const textZ = try init.gpa.dupeSentinel(u8, text, 0);
    defer init.gpa.free(textZ);
    init.gpa.free(text);

    if (runLexer) {
        std.log.info("Running lexer...", .{});
        var lexer = try Lexer.init(init.gpa);
        defer lexer.deinit();

        const tokens = try lexer.tokenize(textZ);
        const tokensJoined = try mem.join(init.gpa, "  ", tokens);
        defer init.gpa.free(tokensJoined);

        std.log.info("Generated tokens:\n  {s}", .{tokensJoined});
    }
}
