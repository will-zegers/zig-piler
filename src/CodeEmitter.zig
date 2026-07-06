// zig fmt: off
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Assembler = @import("Assembler.zig");

const CodeEmitter = @This();

allocator: Allocator,
instructions: ArrayList([]const u8),

pub fn init(allocator: Allocator, ast: Assembler.AST) !CodeEmitter {
    var instructions: ArrayList([]const u8) = .empty;

    const functionDef = try std.fmt.allocPrint(allocator, ".global {0s}\n{0s}:", .{ast.function.name});
    defer allocator.free(functionDef);

    try instructions.append(allocator, try allocator.dupe(u8, functionDef));
    for (ast.function.instructions) |instr| {
        var instructionBuilder: ArrayList([]const u8) = .empty; // essentially a string builder
        defer instructionBuilder.deinit(allocator);

        try instructionBuilder.append(allocator, "  ");
        try instructionBuilder.append(allocator, @tagName(instr.mnemonic));
        if (instr.src) |src| {
            switch (src) {
                .Imm => {
                    try instructionBuilder.append(allocator, " $");
                    try instructionBuilder.append(allocator, src.Imm);
                },
                .Reg => {
                    try instructionBuilder.append(allocator, " %");
                    try instructionBuilder.append(allocator, @tagName(src.Reg));
                }
            }
            if (instr.dst) |dst| {
                switch (dst) {
                    .Imm => {
                        try instructionBuilder.append(allocator, " $");
                        try instructionBuilder.append(allocator, dst.Imm);
                    },
                    .Reg => {
                        try instructionBuilder.append(allocator, " %");
                        try instructionBuilder.append(allocator, @tagName(dst.Reg));
                    }
                }
            }
        }
        const instruction = try std.mem.join(allocator, "", instructionBuilder.items); // build
        try instructions.append(allocator, instruction);
    }
    switch (builtin.os.tag) {
        .linux => try instructions.append(allocator, try allocator.dupe(u8, ".section .note.GNU-stack,\"\",@progbits")),
        else => unreachable, // only running this on linux atm
    }

    return .{ .allocator = allocator, .instructions = instructions };
}

pub fn writeToFile(self: CodeEmitter, io: Io, outputPath: []const u8) !void {
    const instructions = try std.mem.join(self.allocator, "\n", self.instructions.items);
    defer self.allocator.free(instructions);

    const outputFile = try Io.Dir.cwd().createFile(io, outputPath, .{ .read = false });
    defer outputFile.close(io);

    try outputFile.writeStreamingAll(io, instructions);
}

pub fn deinit(self: *CodeEmitter) void {
    for (self.instructions.items) |instruction| {
        self.allocator.free(instruction);
    }
    self.instructions.deinit(self.allocator);
}
