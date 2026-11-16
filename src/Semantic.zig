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

pub fn run(allocator: Allocator, tree: *Parser.AST, textLines: [][]const u8) Allocator.Error!Symbol.Table {
    var reporter = Error.Reporter.init(textLines);

    var context: Context = try .init(allocator, &reporter);
    defer context.deinit();

    try Resolver.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    try LoopLabeler.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    var symbolTable: Symbol.Table = .init(allocator);
    try TypeChecker.run(allocator, &symbolTable, &reporter, tree);
    if (reporter.errorFlag) process.exit(1);

    return symbolTable;
}
