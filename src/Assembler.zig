// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const TAC = @import("TAC.zig");

const Patcher = @import("Assembler/Patcher.zig");
const instruction = @import("Assembler/instruction.zig");
pub const Operand = instruction.Operand;
pub const Reg = instruction.Reg;
const ARG_REGISTERS = instruction.ARG_REGISTERS;
const INT_SIZE_BYTES = instruction.INT_SIZE_BYTES;
const WORD_SIZE_BYTES = instruction.WORD_SIZE_BYTES;
const Instruction = instruction.Instruction;
const Unary = instruction.Unary;
const Ret = instruction.Ret;
const Binary = instruction.Binary;
const Mov = instruction.Mov;
const Jmp = instruction.Jmp;
const JmpCC = instruction.JmpCC;
const Label = instruction.Label;
const AllocateStack = instruction.AllocateStack;
const DeallocateStack = instruction.DeallocateStack;
const InstructionList = instruction.InstructionList;

const Assembler = @This();

pub const Assembly = Program;

const Program = struct {
    allocator: Allocator,
    functions: []Function,

    pub fn deinit(self: *Assembly) void {
        for (self.functions) |*function| {
            function.deinit();
        }
        self.allocator.free(self.functions);
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: []const u8,
    instructions: []Instruction,

    pub fn deinit(self: *Function) void {
        defer self.allocator.free(self.instructions);
    }
};

pub fn assemble(allocator: Allocator, tree: TAC.Program) Assembly {
    var functions: ArrayList(Function) = .empty;
    for (tree.functions) |function| {
        functions.append(allocator, assembleFunction(allocator, function)) catch allocError();
    }

    return .{
        .allocator = allocator,
        .functions = functions.toOwnedSlice(allocator) catch allocError(),
    };
}

pub fn assembleFunction(allocator: Allocator, function: TAC.Function) Function {
    var instructionList: InstructionList = .empty;

    // Move arguments into memory
    var i: usize = 0;
    while (i < function.params.len and i < ARG_REGISTERS.len) {
        const src: Operand = .{ .Reg = ARG_REGISTERS[i] };
        const dst: Operand = .{ .Pseudo = function.params[i].unique.? };
        instructionList.append(allocator, .{ .Mov = .{ .src = src, .dst = dst } }) catch allocError();

        i += 1;
    }

    var pseudoMap: std.StringHashMap(isize) = .init(allocator);
    defer pseudoMap.deinit();

    // Since the stack args already exist in memory, add an entry to the pseudo
    // table for the already existing stack offsets
    var stackOffset: isize = 2 * WORD_SIZE_BYTES; // return address + callee base-pointer
    while (i < function.params.len) {
        pseudoMap.put(function.params[i].unique.?, stackOffset) catch allocError();

        i += 1;
        stackOffset += WORD_SIZE_BYTES;
    }

    // First pass to build Assembly AST
    for (function.body) |instr| {
        const assembly = switch (instr) {
            .Unary => |unary| Unary.toAssembly(allocator, unary),
            .Return => |ret| Ret.toAssembly(allocator, ret),
            .Binary => |binary| Binary.toAssembly(allocator, binary),
            .Copy => |copy| Mov.toAssembly(allocator, copy),
            .Jump => |jmp| Jmp.toAssembly(allocator, jmp),
            .JumpIfZero => JmpCC.toAssembly(allocator, instr),
            .JumpIfNotZero => JmpCC.toAssembly(allocator, instr),
            .Label => |label| Label.toAssembly(allocator, label),
            .FunCall => |funCall| instruction.funCallToAssembly(allocator, funCall) catch allocError(),
        };
        defer allocator.free(assembly);

        instructionList.appendSlice(allocator, assembly) catch allocError();
    }

    // Second pass, replace Pseudo registers with stack locations and prepend the prelude
    setupStack(allocator, &instructionList, &pseudoMap);

    // Find illegal instructions (see specifications in the Patcher module)
    var instructions = instructionList.toOwnedSlice(allocator) catch allocError();
    instructions = Patcher.patchInstructions(allocator, instructions);

    return .{
        .allocator = allocator,
        .name = function.name,
        .instructions = instructions,
    };
}

fn setupStack(allocator: Allocator, instructions: *InstructionList, pseudoMap: *StringHashMap(isize)) void{
    var localStack: isize = 0;

    for (instructions.items) |*instr| {
        switch (instr.*) {
            .Mov => |*mov| {
                replaceIfPseudo(pseudoMap, &localStack, &mov.src);
                replaceIfPseudo(pseudoMap, &localStack, &mov.dst);
            },
            .Unary => |*unary| {
                replaceIfPseudo(pseudoMap, &localStack, &unary.operand);
            },
            .Binary => |*binary| {
                replaceIfPseudo(pseudoMap, &localStack, &binary.src);
                replaceIfPseudo(pseudoMap, &localStack, &binary.dst);
            },
            .Idiv => |*idiv| {
                replaceIfPseudo(pseudoMap, &localStack, &idiv.operand);
            },
            .Cmp => |*cmp| {
                replaceIfPseudo(pseudoMap, &localStack, &cmp.arg1);
                replaceIfPseudo(pseudoMap, &localStack, &cmp.arg2);
            },
            .SetCC => |*setcc| {
                replaceIfPseudo(pseudoMap, &localStack, &setcc.operand);
            },
            .Push => |*push| {
                replaceIfPseudo(pseudoMap, &localStack, &push.operand);
            },
            else => {},
        }
    }

    // Prepend the instructions with stack space allocation based on the number of
    // pseudo registers (i.e. local variables) replaced with memory
    instructions.insert(allocator, 0, .{ .AllocateStack = .{ .stackSpace = -localStack } }) catch allocError();
}

/// Replace 'Psuedo' registers generated in the first pass with memory locations
/// on the stack
fn replaceIfPseudo(map: *std.StringHashMap(isize), stackPointer: *isize, operand: *Operand) void {
    if (operand.* == .Pseudo) {
        const key = operand.Pseudo;
        // If the pseudo register has not been mapped to a location on the stack,
        // map it to the location in the local stack space
        if (map.get(key) == null) {
            stackPointer.* -= INT_SIZE_BYTES;
            map.put(key, stackPointer.*) catch allocError();
        }
        const value = map.get(key).?;
        operand.* = .{ .Stack = value };
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
