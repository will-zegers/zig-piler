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

    const functionDefTemplate =
        \\  .globl {0s}
        \\{0s}:
        \\  pushq   %rbp
        \\  movq    %rsp, %rbp
    ;

    const functionDefinition = try std.fmt.allocPrint(allocator, functionDefTemplate, .{ast.function.name});
    const localPrefix = switch (builtin.os.tag) {
        .linux => ".L",
        else => unreachable, // only running this on linux atm
    };

    try instructions.append(allocator, functionDefinition);

    for (ast.function.instructions.items) |instruction| {
        switch (instruction) {
            .AllocStack => |allocStack| {
                const template =
                    \\  subq    ${d}, %rsp
                ;
                const instr = try std.fmt.allocPrint(allocator, template, .{allocStack.stackPointer});
                try instructions.append(allocator, instr);
            },
            .Mov => |mov| {
                const template =
                    \\  movq    {s}, {s}
                ;
                const src = try getOperandString(allocator, mov.src);
                defer allocator.free(src);
                const dst = try getOperandString(allocator, mov.dst);
                defer allocator.free(dst);

                const instr = try std.fmt.allocPrint(allocator, template, .{src, dst});
                try instructions.append(allocator, instr);
            },
            .Ret => {
                const instr =
                    \\  movq    %rbp, %rsp
                    \\  popq    %rbp
                    \\  ret
                ;
                try instructions.append(allocator, try allocator.dupe(u8, instr));
            },
            .Unary => |unary| {
                const template =
                    \\  {s}    {s}
                ;
                const operator = switch (unary.operator) {
                    .Complement => "notq",
                    .Negate => "negq",
                    .Not => "notl",
                };
                const operand = try getOperandString(allocator, unary.operand);
                defer allocator.free(operand);

                const instr = try std.fmt.allocPrint(allocator, template, .{operator, operand});
                try instructions.append(allocator, instr);
            },
            .Binary => |binary| {
                const template =
                    \\  {s}    {s}, {s}
                ;
                const operator = switch (binary.operator) {
                    .Add => "addq",
                    .Sub => "subq",
                    .Mul => "imulq",
                    .AndB => "andq",
                    .OrB => "orq",
                    .Xor => "xorq",
                    .SAL => "salq",
                    .SAR => "sarq",
                    else => unreachable,
                };
                const src = try getOperandString(allocator, binary.src);
                defer allocator.free(src);
                const dst = try getOperandString(allocator, binary.dst);
                defer allocator.free(dst);

                const instr = try std.fmt.allocPrint(allocator, template, .{operator, src, dst});
                try instructions.append(allocator, instr);
            },
            .Cqo => {
                const instr =
                    \\  cqo
                ;
                try instructions.append(allocator, try allocator.dupe(u8, instr));
            },
            .Idiv => |idiv| {
                const template =
                    \\  idivq    {s}
                ;
                const operand = try getOperandString(allocator, idiv.operand);
                defer allocator.free(operand);

                const instr = try std.fmt.allocPrint(allocator, template, .{operand});
                try instructions.append(allocator, instr);
            },
            .Cmp => |cmp| {
                const template =
                    \\  cmpq    {s}, {s}
                ;
                const arg1 = try getOperandString(allocator, cmp.arg1);
                defer allocator.free(arg1);
                const arg2 = try getOperandString(allocator, cmp.arg2);
                defer allocator.free(arg2);

                const instr = try std.fmt.allocPrint(allocator, template, .{arg1, arg2});
                try instructions.append(allocator, instr);
            },
            .Jmp => |jmp| {
                const template =
                    \\  jmp    {s}{s}
                ;

                const instr = try std.fmt.allocPrint(allocator, template, .{localPrefix, jmp.target});
                try instructions.append(allocator, instr);
            },
            .JmpCC => |jmp| {
                const template =
                    \\  j{s}    {s}{s}
                ;
                const condCode = switch (jmp.condition) {
                    .E => "e",
                    .NE => "ne",
                    else => unreachable,
                };

                const instr = try std.fmt.allocPrint(allocator, template, .{condCode, localPrefix, jmp.target});
                try instructions.append(allocator, instr);
            },
            .SetCC => |*set| {
                const template =
                    \\  set{s}   {s}
                ;
                const condCode = switch (set.condition) {
                    .E => "e",
                    .G => "g",
                    .GE => "ge",
                    .L => "l",
                    .LE => "le",
                    .NE => "ne",
                };
                const byteOperand = if (set.operand == .Reg)
                    Assembler.Reg.toByteRegister(set.operand)
                else
                    set.operand;

                const operand = try getOperandString(allocator, byteOperand);
                defer allocator.free(operand);

                const instr = try std.fmt.allocPrint(allocator, template, .{condCode, operand});
                try instructions.append(allocator, instr);

            },
            .Label => |label| {
                const template =
                    \\{s}{s}:
                ;
                const instr = try std.fmt.allocPrint(allocator, template, .{localPrefix, label.id});
                try instructions.append(allocator, instr);
            },
        }
    }

    switch (builtin.os.tag) {
        .linux => try instructions.append(allocator, try allocator.dupe(u8, ".section .note.GNU-stack,\"\",@progbits")),
        else => unreachable, // only running this on linux atm
    }
    try instructions.append(allocator, try allocator.dupe(u8, "\n")); // need newline at end of file

    return .{ .allocator = allocator, .instructions = instructions };
}

fn getOperandString(allocator: Allocator, operand: Assembler.Operand) ![]const u8 {
    return switch(operand) {
        .Imm => |op|   try std.fmt.allocPrint(allocator, "{c}{s}", .{'$', op}),
        .Reg => |op|   try std.fmt.allocPrint(allocator, "{c}{s}", .{'%', @tagName(op)}),
        .Stack => |op| try std.fmt.allocPrint(allocator, "{d}{s}", .{op, "(%rbp)"}),
        .Pseudo => unreachable,
    };
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
