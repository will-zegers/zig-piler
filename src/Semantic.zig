// zig fmt: off
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const Resolver = @import("Semantic/Resolver.zig");
const LoopLabeler = @import("Semantic/LoopLabeler.zig");
const TypeChecker = @import("Semantic/TypeChecker.zig");
const Error = @import("Semantic/Error.zig");

const Context = @import("Semantic/Context.zig");
const IdentifierMap = Context.IdentifierMap;

const AST = @import("Parser.zig").AST;

pub fn run(allocator: Allocator, tree: *AST, textLines: [][]const u8) void {
    var reporter = Error.Reporter.init(textLines);

    var context: Context = .init(allocator, &reporter);
    defer context.deinit();

    Resolver.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    LoopLabeler.run(allocator, &context, tree);
    if (reporter.errorFlag) process.exit(1);

    TypeChecker.run(allocator, &reporter, tree);
    if (reporter.errorFlag) process.exit(1);
}
