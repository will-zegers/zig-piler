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

const CodeEmitter = @This();

var LocalStatics: StringHashMap(Assembler.StaticConstant) = undefined;

const UnitSize = enum {
    Long,
    Quad,
};
    const LOCAL_PREFIX = switch (builtin.os.tag) {
        .linux => ".L",
        else => unreachable, // only running this on linux atm
    };

arena: ArenaAllocator,
instructions: ArrayList([]const u8),

pub fn init(allocator: Allocator, ast: Assembler.Assembly) !CodeEmitter {
    var arena: ArenaAllocator = .init(allocator);
    const arenaAllocator = arena.allocator();

    LocalStatics = ast.staticConsts;
    var instructions: ArrayList([]const u8) = .empty;

    // Start with code in the .text section
    for (ast.topLevel) |function| {
        const slice = try emitFunction(arenaAllocator, ast.symbols, function);
        try instructions.appendSlice(arenaAllocator, slice);
    }

    // Followed by the static variables
    var svIter = ast.staticVars.valueIterator();
    while (svIter.next()) |value_ptr| {
        const staticVar = try emitStaticVar(arenaAllocator, value_ptr.*);
        try instructions.appendSlice(arenaAllocator, staticVar);
    }

    // Finally add the static constants to the end
    var scIter = ast.staticConsts.valueIterator();
    while (scIter.next()) |value_ptr| {
        const staticConst = try emitStaticConstant(arenaAllocator, value_ptr.*);
        try instructions.append(arenaAllocator, staticConst);
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

    const fullName = staticVar.name;

    var code: []const u8 = undefined;
    switch (staticVar.initial) {
        .int, .uint => if (staticVar.isZero()) {
            const template =
                \\  .bss
                \\  .align 4
                \\{s}:
                \\  .zero 4
            ;
            code = try allocator.print(template, .{fullName});
        } else {
            const template =
                \\  .data
                \\  .align 4
                \\{s}:
                \\  .long {d}
            ;
            code = if (staticVar.initial == .int)
                try allocator.print(template, .{fullName, staticVar.initial.int})
            else
                try allocator.print(template, .{fullName, staticVar.initial.uint});
        },
        .double, .long, .ulong => if (staticVar.isZero()) {
            const template =
                \\  .bss
                \\  .align 8
                \\{s}:
                \\  .zero 8
            ;
            code = try allocator.print(template, .{fullName});
        } else {
            const template =
                \\  .data
                \\  .align 8
                \\{s}:
                \\  .{s} {d}
            ;
            code = switch (staticVar.initial) {
                .double => try allocator.print(template, .{fullName, "double", staticVar.initial.double}),
                .long => try allocator.print(template, .{fullName, "quad", staticVar.initial.long}),
                .ulong => try allocator.print(template, .{fullName, "quad", staticVar.initial.ulong}),
                else => unreachable,
            };
        },
    }
    try instructions.append(allocator, code);

    return try instructions.toOwnedSlice(allocator);
}

fn emitStaticConstant(allocator: Allocator, staticConst: Assembler.StaticConstant) ![]const u8 {
    const template =
        \\  .section .rodata
        \\  .align {d}
        \\{s}{s}:
        \\  .double {d}
    ;

    return allocator.print(template, .{staticConst.alignment, LOCAL_PREFIX, staticConst.name, staticConst.initial.double});
}

pub fn emitFunction(allocator: Allocator, symbols: StringHashMap(Assembler.Entry), function: Assembler.Function) ![][]const u8 {
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

    try instructions.append(allocator, functionDefinition);

    for (assembly) |instruction| {
        const code = code: switch (instruction) {
            .Binary => |binary| {
                const template =
                    \\  {s}{s}    {s}, {s}
                ;
                const operator = switch (binary.operator) {
                    .Add => "add",
                    .AndB => "and",
                    .Div => "div",
                    .Mul => if (binary.type == .Double) "mul" else "imul",
                    .OrB => "or",
                    .SAL => "sal",
                    .SAR => "sar",
                    .SHL => "shl",
                    .SHR => "shr",
                    .Sub => "sub",
                    .Xor => "xor",
                    else => unreachable,
                };
                const suffix = if (binary.type == .Double and binary.operator == .Xor) "ps" else getSuffix(binary.type);
                const src = getOperandString(allocator, binary.src, binary.type);
                const dst = getOperandString(allocator, binary.dst, binary.type);

                break :code allocator.print(template, .{operator, suffix, src, dst});
            },
            .Call => |call| {
                const template =
                    \\  call    {s}{s}
                ;

                break :code if (symbols.get(call.identifier).?.Fun.defined)
                    allocator.print(template, .{call.identifier, ""})
                else
                    allocator.print(template, .{call.identifier, "@PLT"});

            },
            .Cdq => |cdq| {
                const template = switch (cdq.type) {
                    .Double => unreachable,
                    .Long => "  cdq\n",
                    .Quad => "  cqo\n",
                };
                break :code allocator.dupe(u8, template);
            },
            .Cmp => |cmp| {
                const suffix = getSuffix(cmp.type);
                const arg1 = getOperandString(allocator, cmp.arg1, cmp.type);
                const arg2 = getOperandString(allocator, cmp.arg2, cmp.type);
                const template: []const u8 = switch (cmp.type) {
                    .Long, .Quad => break :code allocator.print("  cmp{s}    {s}, {s}", .{suffix, arg1, arg2}),
                    .Double => break :code allocator.print("  comi{s}    {s}, {s}", .{suffix, arg1, arg2}),
                };

                break :code allocator.print(template, .{suffix, arg1, arg2});
            },
            .Cvtsi2sd => |cvt| {
                const template =
                    \\  cvtsi2sd{s} {s}, {s}
                ;
                const suffix = getSuffix(cvt.type);
                const src = getOperandString(allocator, cvt.src, cvt.type);
                const dst = getOperandString(allocator, cvt.dst, cvt.type);

                break :code allocator.print(template, .{suffix, src, dst});
            },
            .Cvttsd2si => |cvt| {
                const template =
                    \\  cvttsd2si{s} {s}, {s}
                ;
                const suffix = getSuffix(cvt.type);
                const src = getOperandString(allocator, cvt.src, cvt.type);
                const dst = getOperandString(allocator, cvt.dst, cvt.type);

                break :code allocator.print(template, .{suffix, src, dst});
            },
            .Div => |div| {
                const template =
                    \\  div{s}   {s}
                ;
                const suffix = getSuffix(div.type);
                const operand = getOperandString(allocator, div.operand, div.type);

                break :code allocator.print(template, .{suffix, operand});
            },
            .Idiv => |idiv| {
                const template =
                    \\  idiv{s}   {s}
                ;
                const suffix = getSuffix(idiv.type);
                const operand = getOperandString(allocator, idiv.operand, idiv.type);

                break :code allocator.print(template, .{suffix, operand});
            },
            .Jmp => |jmp| {
                const template =
                    \\  jmp    {s}{s}
                ;

                break :code allocator.print(template, .{LOCAL_PREFIX, jmp.target});
            },
            .JmpCC => |jmp| {
                const template =
                    \\  j{s}    {s}{s}
                ;
                const condCode = @tagName(jmp.condition); // will only be 'e' or 'ne';

                break :code allocator.print(template, .{condCode, LOCAL_PREFIX, jmp.target});
            },
            .Label => |label| {
                const template =
                    \\{s}{s}:
                ;
                break :code allocator.print(template, .{LOCAL_PREFIX, label.id});
            },
            .Mov => |mov| {
                const template =
                    \\  mov{s}    {s}, {s}
                ;
                const suffix = getSuffix(mov.type);
                const src = getOperandString(allocator, mov.src, mov.type);
                const dst = getOperandString(allocator, mov.dst, mov.type);

                break :code allocator.print(template, .{suffix, src, dst});
            },
            .Movsx => |movsx| {
                const template =
                    \\  movs{s}  {s}, {s}

                ;
                // TODO: extend to more sizes when needed
                const suffix = "lq";
                const src = getOperandString(allocator, movsx.src, .Long);
                const dst = getOperandString(allocator, movsx.dst, .Quad);

                break :code allocator.print(template, .{suffix, src, dst});
            },
            .Movzx => unreachable,
            .Push => |push| {
                const template =
                    \\  pushq  {s}
                ;
                const operand = getOperandString(allocator, push.operand, .Quad);
                break :code allocator.print(template, .{operand});
            },
            .Ret =>  {
                const instr =
                    \\  movq    %rbp, %rsp
                    \\  popq    %rbp
                    \\  ret
                ;
                break :code allocator.print(instr, .{});
            },
            .SetCC => |*set| {
                const template =
                    \\  set{s}   {s}
                ;
                const condCode = @tagName(set.condition);
                const operand = getOperandString(allocator, set.operand, .Long);

                break :code allocator.print(template, .{condCode, operand});

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
                const suffix = getSuffix(unary.type);
                const operand = getOperandString(allocator, unary.operand, unary.type);

                break :code allocator.print(template, .{operator, suffix, operand});
            },
        } catch allocError();
        try instructions.append(allocator, code);
    }

    return try instructions.toOwnedSlice(allocator);
}

fn getSuffix(t: Assembler.Type) []const u8 {
    return switch (t) {
        .Double => "sd",
        .Long => "l",
        .Quad => "q",
    };
}

fn getOperandString(allocator: Allocator, operand: Assembler.Operand, t: Assembler.Type) []const u8 {
    return switch(operand) {
        .Imm => |op| allocator.print("{c}{d}", .{'$', op}),
        .Reg => |op| getRegisterName(allocator, op, t),
        .Stack => |op| allocator.print("{d}(%rbp)", .{op}),
        .Data => |op| {
            return if (LocalStatics.contains(operand.Data))
                allocator.print("{s}{s}(%rip)", .{LOCAL_PREFIX, op}) catch allocError()
            else
                allocator.print("{s}(%rip)", .{op}) catch allocError();
        },
        .Pseudo => unreachable,
    } catch allocError();
}

fn getRegisterName(allocator: Allocator, reg: Assembler.Reg, t: Assembler.Type) []const u8 {
    switch(reg) {
        .ax, .cx, .dx, .di, .si => {
            return switch (t) {
                .Long => allocator.print("%e{s}", .{@tagName(reg)}),
                .Quad => allocator.print("%r{s}", .{@tagName(reg)}),
                .Double =>  unreachable,
            } catch allocError();
        },
        .r8, .r9, .r10, .r11 => {
            return switch (t) {
                .Long => allocator.print("%{s}d", .{@tagName(reg)}),
                .Quad => allocator.print("%{s}", .{@tagName(reg)}),
                .Double =>  unreachable,
            } catch allocError();
        },
        .cl => return allocator.print("%{s}", .{@tagName(reg)}) catch allocError(),
        .sp => return allocator.print("%rsp", .{}) catch allocError(),
        else => return allocator.print("%{s}", .{@tagName(reg)}) catch allocError(),
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
