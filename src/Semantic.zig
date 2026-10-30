// zig fmt: off
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;
const StringHashMap = std.StringHashMap;

const Resolver = @import("Semantic/Resolver.zig");
const LoopLabeler = @import("Semantic/LoopLabeler.zig");
const TypeChecker = @import("Semantic/TypeChecker.zig");
const Error = @import("Semantic/Error.zig");

const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;
const Symbols = @import("Semantic/Symbols.zig");

const Parser = @import("Parser.zig");

pub const AST = struct {
    tree: Parser.AST,
    symbols: Symbols.Table,

    pub fn deinit(self: *AST) void {
        self.symbols.deinit();
    }
};

pub fn run(allocator: Allocator, tree: *Parser.AST, textLines: [][]const u8) AST {
    var reporter = Error.Reporter.init(textLines);

    var context: Context = .init(allocator, &reporter);
    defer context.deinit();

    Resolver.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    LoopLabeler.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    var symbols: Symbols.Table = .init(allocator);
    TypeChecker.run(&symbols, &reporter, tree);
    if (reporter.errorFlag) process.exit(1);

    return .{ .tree = tree.*, .symbols = symbols };
}
