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
    const assembly = ast.function.instructions.items;

    // Assembly instructions will be 1:1 with the []const u8 entries in the emitted code, plus
    // a few bookkeeping and prelude/epilogue instructions
    var instructions = try ArrayList([]const u8).initCapacity(allocator, assembly.len + 16);

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

    instructions.appendAssumeCapacity(functionDefinition);

    for (assembly) |instruction| {
        const code = code: switch (instruction) {
            .AllocStack => |allocStack| {
                const template =
                    \\  subq    ${d}, %rsp
                ;
                break :code std.fmt.allocPrint(allocator, template, .{allocStack.stackPointer});
            },
            .Mov => |mov| {
                const template =
                    \\  movq    {s}, {s}
                ;
                const src = getOperandString(allocator, mov.src);
                defer allocator.free(src);
                const dst = getOperandString(allocator, mov.dst);
                defer allocator.free(dst);

                break :code std.fmt.allocPrint(allocator, template, .{src, dst});
            },
            .Ret =>  {
                const instr =
                    \\  movq    %rbp, %rsp
                    \\  popq    %rbp
                    \\  ret
                ;
                break :code allocator.dupe(u8, instr);
            },
            .Unary => |unary| {
                const template =
                    \\  {s}    {s}
                ;
                const operator = switch (unary.operator) {
                    .Complement => "notq",
                    .Negate => "negq",
                    .Not => unreachable, // implemented as x == 0
                };
                const operand = getOperandString(allocator, unary.operand);
                defer allocator.free(operand);

                break :code std.fmt.allocPrint(allocator, template, .{operator, operand});
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
                const src = getOperandString(allocator, binary.src);
                defer allocator.free(src);
                const dst = getOperandString(allocator, binary.dst);
                defer allocator.free(dst);

                break :code std.fmt.allocPrint(allocator, template, .{operator, src, dst});
            },
            .Cqo =>  {
                const instr =
                    \\  cqo
                ;
                break :code allocator.dupe(u8, instr);
            },
            .Idiv => |idiv| {
                const template =
                    \\  idivq    {s}
                ;
                const operand = getOperandString(allocator, idiv.operand);
                defer allocator.free(operand);

                break :code std.fmt.allocPrint(allocator, template, .{operand});
            },
            .Cmp => |cmp| {
                const template =
                    \\  cmpq    {s}, {s}
                ;
                const arg1 = getOperandString(allocator, cmp.arg1);
                defer allocator.free(arg1);
                const arg2 = getOperandString(allocator, cmp.arg2);
                defer allocator.free(arg2);

                break :code std.fmt.allocPrint(allocator, template, .{arg1, arg2});
            },
            .Jmp => |jmp| {
                const template =
                    \\  jmp    {s}{s}
                ;

                break :code std.fmt.allocPrint(allocator, template, .{localPrefix, jmp.target});
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

                break :code std.fmt.allocPrint(allocator, template, .{condCode, localPrefix, jmp.target});
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

                const operand = getOperandString(allocator, byteOperand);
                defer allocator.free(operand);

                break :code std.fmt.allocPrint(allocator, template, .{condCode, operand});

            },
            .Label => |label| {
                const template =
                    \\{s}{s}:
                ;
                break :code std.fmt.allocPrint(allocator, template, .{localPrefix, label.id});
            },
        } catch @panic("Out of memory");
        instructions.appendAssumeCapacity(code);
    }

    switch (builtin.os.tag) {
        .linux => instructions.appendAssumeCapacity(try allocator.dupe(u8, ".section .note.GNU-stack,\"\",@progbits")),
        else => unreachable, // only running this on linux atm
    }
    instructions.appendAssumeCapacity(try allocator.dupe(u8, "\n")); // need newline at end of file

    return .{ .allocator = allocator, .instructions = instructions };
}

fn getOperandString(allocator: Allocator, operand: Assembler.Operand) []const u8 {
    return switch(operand) {
        .Imm => |op|   std.fmt.allocPrint(allocator, "{c}{s}", .{'$', op}),
        .Reg => |op|   std.fmt.allocPrint(allocator, "{c}{s}", .{'%', @tagName(op)}),
        .Stack => |op| std.fmt.allocPrint(allocator, "{d}{s}", .{op, "(%rbp)"}),
        .Pseudo => unreachable,
    } catch @panic("Out of memory");
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
