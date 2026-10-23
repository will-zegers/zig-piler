// zig fmt: off
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const builtin = @import("builtin");

const Assembler = @import("Assembler.zig");

const REG_PREFIX: []const u8 = "e";
const GP_REG_SUFFIX: []const u8 = "d";
const INSTR_SUFFIX: []const u8 = "l";

const CodeEmitter = @This();

allocator: Allocator,
instructions: ArrayList([]const u8),

pub fn init(allocator: Allocator, ast: Assembler.Assembly) !CodeEmitter {
    var instructions: ArrayList([]const u8) = .empty;
    for (ast.functions) |function| {
        const slice = try emitFunction(allocator, function);
        defer allocator.free(slice);

        try instructions.appendSlice(allocator, slice);
    }

    switch (builtin.os.tag) {
        .linux => instructions.appendAssumeCapacity(try allocator.dupe(u8, ".section .note.GNU-stack,\"\",@progbits")),
        else => unreachable, // only running this on linux atm
    }
    instructions.appendAssumeCapacity(try allocator.dupe(u8, "\n")); // need newline at end of file

    return .{ .allocator = allocator, .instructions = instructions };
}

pub fn emitFunction(allocator: Allocator, function: Assembler.Function) ![][]const u8 {
    const assembly = function.instructions;

    // Assembly instructions will be 1:1 with the []const u8 entries in the emitted code, plus
    // a few bookkeeping and prelude/epilogue instructions
    var instructions = try ArrayList([]const u8).initCapacity(allocator, assembly.len + 16);

    const functionDefTemplate =
        \\  .globl {0s}
        \\{0s}:
        \\  pushq   %rbp
        \\  movq    %rsp, %rbp
    ;

    const functionDefinition = try allocator.print(functionDefTemplate, .{function.name});
    const labelPrefix = switch (builtin.os.tag) {
        .linux => ".L",
        else => unreachable, // only running this on linux atm
    };

    instructions.appendAssumeCapacity(functionDefinition);

    for (assembly) |instruction| {
        const code = code: switch (instruction) {
            .AllocateStack => |allocStack| {
                const template =
                    \\  subq    ${d}, %rsp
                ;
                break :code allocator.print(template, .{allocStack.stackSpace});
            },
            .DeallocateStack => |deallocStack| {
                const template =
                    \\  addq    ${d}, %rsp
                ;
                break :code allocator.print(template, .{deallocStack.int});
            },
            .Push => |push| {
                const template =
                    \\  pushq   {s}
                ;
                const operand = getOperandString(allocator, push.operand);
                defer allocator.free(operand);
                break :code allocator.print(template, .{operand});
            },
            .Mov => |mov| {
                const template =
                    \\  mov{s}    {s}, {s}
                ;
                const src = getOperandString(allocator, mov.src);
                defer allocator.free(src);
                const dst = getOperandString(allocator, mov.dst);
                defer allocator.free(dst);

                break :code allocator.print(template, .{INSTR_SUFFIX, src, dst});
            },
            .Call => |call| {
                const template =
                    \\  call    {s}
                ;
                break :code allocator.print(template, .{call.identifier});
            },
            .Ret =>  {
                const instr =
                    \\  movq    %rbp, %rsp
                    \\  popq    %rbp
                    \\  ret
                ;
                break :code allocator.print(instr, .{});
            },
            .Unary => |unary| {
                const template =
                    \\  {s}{s}    {s}
                ;
                const operator = switch (unary.operator) {
                    .Complement => "not",
                    .Negate => "neg",
                    .Inc => "inc",
                    .Dec => "dec",
                    .Not => unreachable, // implemented as x == 0
                };
                const operand = getOperandString(allocator, unary.operand);
                defer allocator.free(operand);

                break :code allocator.print(template, .{operator, INSTR_SUFFIX, operand});
            },
            .Binary => |binary| {
                const template =
                    \\  {s}{s}    {s}, {s}
                ;
                const operator = switch (binary.operator) {
                    .Add => "add",
                    .Sub => "sub",
                    .Mul => "imul",
                    .AndB => "and",
                    .OrB => "or",
                    .Xor => "xor",
                    .SAL => "sal",
                    .SAR => "sar",
                    else => unreachable,
                };
                const src = getOperandString(allocator, binary.src);
                defer allocator.free(src);
                const dst = getOperandString(allocator, binary.dst);
                defer allocator.free(dst);

                break :code allocator.print(template, .{operator, INSTR_SUFFIX, src, dst});
            },
            .Cdq =>  {
                const instr =
                    \\  cdq
                ;
                break :code allocator.dupe(u8, instr);
            },
            .Idiv => |idiv| {
                const template =
                    \\  idiv{s}   {s}
                ;
                const operand = getOperandString(allocator, idiv.operand);
                defer allocator.free(operand);

                break :code allocator.print(template, .{INSTR_SUFFIX, operand});
            },
            .Cmp => |cmp| {
                const template =
                    \\  cmp{s}    {s}, {s}
                ;
                const arg1 = getOperandString(allocator, cmp.arg1);
                defer allocator.free(arg1);
                const arg2 = getOperandString(allocator, cmp.arg2);
                defer allocator.free(arg2);

                break :code allocator.print(template, .{INSTR_SUFFIX, arg1, arg2});
            },
            .Jmp => |jmp| {
                const template =
                    \\  jmp    {s}{s}
                ;

                break :code allocator.print(template, .{labelPrefix, jmp.target});
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

                break :code allocator.print(template, .{condCode, labelPrefix, jmp.target});
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

                const operand = getOperandString(allocator, set.operand);
                defer allocator.free(operand);

                break :code allocator.print(template, .{condCode, operand});

            },
            .Label => |label| {
                const template =
                    \\{s}{s}:
                ;
                break :code allocator.print(template, .{labelPrefix, label.id});
            },
        } catch allocError();
        instructions.appendAssumeCapacity(code);
    }

    return instructions.toOwnedSlice(allocator) catch allocError();
}

fn getOperandString(allocator: Allocator, operand: Assembler.Operand) []const u8 {
    return switch(operand) {
        .Imm => |op| allocator.print("{c}{d}", .{'$', op}),
        .Reg => |op| getRegisterName(allocator, op),
        .Stack => |op| allocator.print("{d}(%rbp)", .{op}),
        .Pseudo => unreachable,
    } catch allocError();
}

fn getRegisterName(allocator: Allocator, reg: Assembler.Reg) []const u8 {
    return switch(reg) {
        .ax, .cx, .dx, .di, .si => allocator.print("%{s}{s}", .{REG_PREFIX, @tagName(reg)}),
        .r8, .r9, .r10, .r11 => allocator.print("%{s}{s}", .{@tagName(reg), GP_REG_SUFFIX}),
        else => allocator.print("%{s}", .{@tagName(reg)}),
    } catch allocError();
}

pub fn writeToFile(self: CodeEmitter, io: Io, outputPath: []const u8) !void {
    const instructions = try mem.join(self.allocator, "\n", self.instructions.items);
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

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
