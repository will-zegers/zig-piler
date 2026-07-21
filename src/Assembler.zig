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
            switch (instr) {
                .Unary => |unary| Unary.append(allocator, &instructions, unary),
                .Return => |ret| Ret.append(allocator, &instructions, ret),
                .Binary => |binary| Binary.append(allocator, &instructions, binary),
                .Copy => |copy| Mov.append(allocator, &instructions, copy),
                .Jump => |jmp| Jmp.append(allocator, &instructions, jmp),
                .JumpIfZero => JmpCC.append(allocator, &instructions, instr),
                .JumpIfNotZero => JmpCC.append(allocator, &instructions, instr),
                .Label => |label| Label.append(allocator, &instructions, label),
            }
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
        AllocStack.prepend(allocator, stackPointer, instructions);
    }

    fn replaceIfPseudo(map: *std.StringHashMap(isize), stackPointer: *isize, operand: *Operand) void {
        if (operand.*.isPseudo()) {
            const key = operand.*.Pseudo;
            if (map.get(key) == null) {
                map.put(key, stackPointer.*) catch std.process.exit(1);
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
