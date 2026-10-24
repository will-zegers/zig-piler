const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

const File = @This();

allocator: Allocator,
text: [:0]const u8,
lines: [][]const u8,
outputSrc: []const u8,

/// Based on the provided input file, gather up all the necessary input (text
/// that will be fed to the lexer, a list of file lines for error reporting)
/// and names for output files (binary and source .s files)
pub fn process(allocator: Allocator, io: std.Io, inputFile: []const u8) !File {
    const rawText = try std.Io.Dir.cwd().readFileAlloc(io, inputFile, allocator, .unlimited);
    defer allocator.free(rawText);

    const text = try allocator.dupeSentinel(u8, rawText, 0);

    const baseName: []const u8 = getBaseName(inputFile);
    const outputSrc = try allocator.print("{s}.s", .{baseName});

    var it = mem.splitScalar(u8, text, '\n');
    var list: ArrayList([]const u8) = .empty;
    while (it.next()) |line| {
        try list.append(allocator, line);
    }
    const lines = try list.toOwnedSlice(allocator);

    return .{ .allocator = allocator, .text = text, .lines = lines, .outputSrc = outputSrc };
}

pub fn deinit(self: File) void {
    self.allocator.free(self.text);
    self.allocator.free(self.lines);
    self.allocator.free(self.outputSrc);
}

/// Based on the input file name, generate an output source name based on the last
/// position of '.' (e.g. compiled output for "myprogram.c" will be "myprogram")
pub fn getBaseName(inputFile: []const u8) []const u8 {
    var outputBin = inputFile;
    for (1..inputFile.len + 1) |i| {
        const backIndex = inputFile.len - i;
        if (inputFile[backIndex] == '.') {
            outputBin = inputFile[0..backIndex];
            break;
        }
    }
    return outputBin;
}
