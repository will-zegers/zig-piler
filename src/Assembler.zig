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
const InstructionList = instruction.InstructionList;

const Assembler = @This();

const WORD_SIZE: isize = 8;

pub const AST = struct {
    allocator: Allocator,
    function: Function,

    pub fn deinit(self: *AST) void {
        self.function.deinit();
    }
};

pub fn codeGen(allocator: Allocator, ast: TAC.Tacky) AST {
    const program: Program = .init(allocator, ast);
    return .{ .allocator = allocator, .function = program.function };
}

const Program = struct {
    allocator: Allocator,
    function: Function,

    pub fn init(allocator: Allocator, program: TAC.Tacky) Program {
        return .{
            .allocator = allocator,
            .function = Function.init(allocator, program.function)
        };
    }
};

const Function = struct {
    allocator: Allocator,
    name: []const u8,
    instructions: []Instruction,

    pub fn init(allocator: Allocator, function: TAC.Function) Function {
        var instrList: InstructionList = .empty;

        // First pass to build Assembly AST
        for (function.body.items) |instr| {
            const assembly = switch (instr) {
                .Unary => |unary| Unary.toAssembly(allocator, unary),
                .Return => |ret| Ret.toAssembly(allocator, ret),
                .Binary => |binary| Binary.toAssembly(allocator, binary),
                .Copy => |copy| Mov.toAssembly(allocator, copy),
                .Jump => |jmp| Jmp.toAssembly(allocator, jmp),
                .JumpIfZero => JmpCC.toAssembly(allocator, instr),
                .JumpIfNotZero => JmpCC.toAssembly(allocator, instr),
                .Label => |label| Label.toAssembly(allocator, label),
            };
            defer allocator.free(assembly);

            instrList.appendSlice(allocator, assembly) catch allocError();
        }

        // Second pass, replace Pseudo registers with stack locations and prepend the prelude
        setupStack(allocator, &instrList);

        // Find illegal instructions (see specifications in the Patcher module)
        var instructions = instrList.toOwnedSlice(allocator) catch allocError();
        instructions = Patcher.patchInstructions(allocator, instructions);

        return .{ .allocator = allocator, .name = function.name, .instructions = instructions, };
    }

    fn setupStack(allocator: Allocator, instructions: *InstructionList) void {
        var pseudoMap: std.StringHashMap(isize) = .init(allocator);
        defer pseudoMap.deinit();
        var stackPointer: isize = -WORD_SIZE;

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
        defer self.allocator.free(self.instructions);
    }
};

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
