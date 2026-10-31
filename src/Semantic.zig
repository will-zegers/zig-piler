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

pub const Symbol = @import("Semantic/Symbols.zig");
const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;

const Parser = @import("Parser.zig");

pub fn run(allocator: Allocator, tree: *Parser.AST, textLines: [][]const u8) Symbol.Table {
    var reporter = Error.Reporter.init(textLines);

    var context: Context = .init(allocator, &reporter);
    defer context.deinit();

    Resolver.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    LoopLabeler.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    var symbolTable: Symbol.Table = .init(allocator);
    TypeChecker.run(allocator, &symbolTable, &reporter, tree);
    if (reporter.errorFlag) process.exit(1);

    return symbolTable;
}
