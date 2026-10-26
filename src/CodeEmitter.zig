// zig fmt: off
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const builtin = @import("builtin");
const ArenaAllocator = std.heap.ArenaAllocator;
const StringHashMap = std.StringHashMap;

const Assembler = @import("Assembler.zig");

const REG_PREFIX: []const u8 = "e";
const GP_REG_SUFFIX: []const u8 = "d";
const INSTR_SUFFIX: []const u8 = "l";

const CodeEmitter = @This();

const UnitSize = enum {
    Long,
    Quad,
};

arena: ArenaAllocator,
instructions: ArrayList([]const u8),

pub fn init(allocator: Allocator, ast: Assembler.Assembly) !CodeEmitter {
    var arena: ArenaAllocator = .init(allocator);
    const arenaAllocator = arena.allocator();

    var instructions: ArrayList([]const u8) = .empty;
    for (ast.topLevel) |topLevel| {
        const slice = switch (topLevel) {
            .Function => |function| try emitFunction(arenaAllocator, function, ast.defined),
            .StaticVariable => |staticVar| try emitStaticVar(arenaAllocator, staticVar),
        };

        try instructions.appendSlice(arenaAllocator, slice);
    }

    switch (builtin.os.tag) {
        .linux => try instructions.append(arenaAllocator, ".section .note.GNU-stack,\"\",@progbits"),
        else => unreachable, // only running this on linux atm
    }
    try instructions.append(arenaAllocator, "\n"); // need newline at end of file

    return .{ .arena = arena, .instructions = instructions };
}

pub fn  emitStaticVar(allocator: Allocator, staticVar: Assembler.StaticVariable) ![][]const u8 {
    var instructions: ArrayList([]const u8) = .empty;

    if (staticVar.global) {
        const global = try allocator.print("  .globl {s}", .{staticVar.name});
        try instructions.append(allocator, global);
    }

    var code: []const u8 = undefined;
    if (staticVar.int == 0) {
        const template =
            \\  .bss
            \\  .align 4
            \\{s}:
            \\  .zero 4
        ;
        code = try allocator.print(template, .{staticVar.name});
    } else {
        const template =
            \\  .data
            \\  .align 4
            \\{s}:
            \\  .long {d}
        ;
        code = try allocator.print(template, .{staticVar.name, staticVar.int});
    }
    try instructions.append(allocator, code);

    return try instructions.toOwnedSlice(allocator);
}

pub fn emitFunction(allocator: Allocator, function: Assembler.Function, defined: StringHashMap(bool)) ![][]const u8 {
    const assembly = function.instructions;

    var instructions: ArrayList([] const u8) = .empty;

    if (function.global) {
        const global = try allocator.print("  .globl {s}", .{function.name});
        try instructions.append(allocator, global);
    }

    const functionDefTemplate =
        \\  .text
        \\{0s}:
        \\  pushq   %rbp
        \\  movq    %rsp, %rbp
    ;

    const functionDefinition = try allocator.print(functionDefTemplate, .{function.name});
    const labelPrefix = switch (builtin.os.tag) {
        .linux => ".L",
        else => unreachable, // only running this on linux atm
    };

    try instructions.append(allocator, functionDefinition);

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
                    \\  pushq  {s}
                ;
                const operand = getOperandString(allocator, push.operand, .Quad);
                break :code allocator.print(template, .{operand});
            },
            .Mov => |mov| {
                const template =
                    \\  mov{s}    {s}, {s}
                ;
                const src = getOperandString(allocator, mov.src, .Long);
                const dst = getOperandString(allocator, mov.dst, .Long);

                break :code allocator.print(template, .{INSTR_SUFFIX, src, dst});
            },
            .Call => |call| {
                const template =
                    \\  call    {s}{s}
                ;

                break :code if (defined.contains(call.identifier))
                    allocator.print(template, .{call.identifier, ""})
                else
                    allocator.print(template, .{call.identifier, "@PLT"});

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
                const operand = getOperandString(allocator, unary.operand, .Long);

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
                const src = getOperandString(allocator, binary.src, .Long);
                const dst = getOperandString(allocator, binary.dst, .Long);

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
                const operand = getOperandString(allocator, idiv.operand, .Long);

                break :code allocator.print(template, .{INSTR_SUFFIX, operand});
            },
            .Cmp => |cmp| {
                const template =
                    \\  cmp{s}    {s}, {s}
                ;
                const arg1 = getOperandString(allocator, cmp.arg1, .Long);
                const arg2 = getOperandString(allocator, cmp.arg2, .Long);

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

                const operand = getOperandString(allocator, set.operand, .Long);

                break :code allocator.print(template, .{condCode, operand});

            },
            .Label => |label| {
                const template =
                    \\{s}{s}:
                ;
                break :code allocator.print(template, .{labelPrefix, label.id});
            },
        } catch allocError();
        try instructions.append(allocator, code);
    }

    return try instructions.toOwnedSlice(allocator);
}

fn getOperandString(allocator: Allocator, operand: Assembler.Operand, size: UnitSize) []const u8 {
    return switch(operand) {
        .Imm => |op| allocator.print("{c}{d}", .{'$', op}),
        .Reg => |op| getRegisterName(allocator, op, size),
        .Stack => |op| allocator.print("{d}(%rbp)", .{op}),
        .Data => |op| allocator.print("{s}(%rip)", .{op}),
        .Pseudo => unreachable,
    } catch allocError();
}

fn getRegisterName(allocator: Allocator, reg: Assembler.Reg, size: UnitSize) []const u8 {
    switch(reg) {
        .ax, .cx, .dx, .di, .si => {
            return switch (size) {
                .Long => allocator.print("%e{s}", .{@tagName(reg)}) catch allocError(),
                .Quad => allocator.print("%r{s}", .{@tagName(reg)}) catch allocError(),
            };
        },
        .r8, .r9, .r10, .r11 => {
            return switch (size) {
                .Long => allocator.print("%{s}d", .{@tagName(reg)}) catch allocError(),
                .Quad => allocator.print("%{s}", .{@tagName(reg)}) catch allocError(),
            };
        },
        .cl => return allocator.print("%{s}", .{@tagName(reg)}) catch allocError(),
    }
}

pub fn writeToFile(self: CodeEmitter, allocator: Allocator, io: Io, outputPath: []const u8) !void {
    const instructions = try mem.join(allocator, "\n", self.instructions.items);
    defer allocator.free(instructions);

    const outputFile = try Io.Dir.cwd().createFile(io, outputPath, .{ .read = false });
    defer outputFile.close(io);

    try outputFile.writeStreamingAll(io, instructions);
}

pub fn deinit(self: *CodeEmitter) void {
    self.arena.deinit();
    // for (self.instructions.items) |instruction| {
    //     self.allocator.free(instruction);
    // }
    // self.instructions.deinit(self.allocator);
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
