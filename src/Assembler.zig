// zig fmt: off
const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const TAC = @import("TAC.zig");

const Patcher = @import("Assembler/Patcher.zig");
const instruction = @import("Assembler/instruction.zig");
pub const Operand = instruction.Operand;
pub const Reg = instruction.Reg;
const Instruction = instruction.Instruction;
const Unary = instruction.Unary;
const Ret = instruction.Ret;
const Binary = instruction.Binary;
const Mov = instruction.Mov;
const Jmp = instruction.Jmp;
const JmpCC = instruction.JmpCC;
const Label = instruction.Label;
const AllocStack = instruction.AllocStack;
const Instructions = instruction.Instructions;

const Assembler = @This();

pub const AST = Program;

const WORD_SIZE: usize = 8;

pub fn codeGen(allocator: Allocator, ast: TAC.IR) AST {
    return .init(allocator, ast);
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, program: TAC.IR) Program {
        return .{
            .allocator = allocator,
            .function = Function.init(allocator, program.function)
        };
    }

    pub fn deinit(self: *Program) void {
        self.function.deinit();
    }
};

const Function = struct {
    allocator: Allocator,
    name: []const u8,
    instructions: Instructions,

    pub fn init(allocator: Allocator, function: TAC.Function) Function {
        var instructions: Instructions = .empty;

        // First pass to build Assembly AST
        for (function.body.items) |instr| {
            const assembly = switch (instr) {
                .Unary => |unary| Unary.assembly(allocator, unary),
                .Return => |ret| Ret.assembly(allocator, ret),
                .Binary => |binary| Binary.assembly(allocator, binary),
                .Copy => |copy| Mov.assembly(allocator, copy),
                .Jump => |jmp| Jmp.assembly(allocator, jmp),
                .JumpIfZero => JmpCC.assembly(allocator, instr),
                .JumpIfNotZero => JmpCC.assembly(allocator, instr),
                .Label => |label| Label.assembly(allocator, label),
            };
            defer allocator.free(assembly);

            instructions.appendSlice(allocator, assembly) catch allocError();
        }

        // Second pass, replace Pseudo registers with stack locations and prepend the prelude
        setupStack(allocator, &instructions);

        // Find illegal instructions (see specifications in the Patcher module)
        instructions = Patcher.patchInstructions(allocator, &instructions);

        return .{ .allocator = allocator, .name = function.name, .instructions = instructions, };
    }

    fn setupStack(allocator: Allocator, instructions: *Instructions) void {
        var pseudoMap: std.StringHashMap(isize) = .init(allocator);
        defer pseudoMap.deinit();
        var stackPointer: isize = -4;

        for (instructions.items) |*instr| {
            switch (instr.*) {
                .Mov => |*mov| {
                    replaceIfPseudo(&pseudoMap, &stackPointer, &mov.src);
                    replaceIfPseudo(&pseudoMap, &stackPointer, &mov.dst);
                },
                .Unary => |*unary| {
                    replaceIfPseudo(&pseudoMap, &stackPointer, &unary.operand);
                },
                .Binary => |*binary| {
                    replaceIfPseudo(&pseudoMap, &stackPointer, &binary.src);
                    replaceIfPseudo(&pseudoMap, &stackPointer, &binary.dst);
                },
                .Idiv => |*idiv| {
                    replaceIfPseudo(&pseudoMap, &stackPointer, &idiv.operand);
                },
                .Cmp => |*cmp| {
                    replaceIfPseudo(&pseudoMap, &stackPointer, &cmp.arg1);
                    replaceIfPseudo(&pseudoMap, &stackPointer, &cmp.arg2);
                },
                .SetCC => |*setcc| {
                    replaceIfPseudo(&pseudoMap, &stackPointer, &setcc.operand);
                },
                else => {},
            }
        }

        instructions.insert(allocator, 0, .{ .AllocStack = .{ .stackPointer = stackPointer } }) catch allocError();
    }

    fn replaceIfPseudo(map: *std.StringHashMap(isize), stackPointer: *isize, operand: *Operand) void {
        if (operand.* == .Pseudo) {
            const key = operand.*.Pseudo;
            if (map.get(key) == null) {
                map.put(key, stackPointer.*) catch allocError();
                stackPointer.* -= WORD_SIZE;
            }
            const value = map.get(key).?;
            operand.* = .{ .Stack = value };
        }
    }

    pub fn deinit(self: *Function) void {
        defer self.instructions.deinit(self.allocator);
    }
};

fn allocError() noreturn {
    @panic("Memory allocation error");
}
