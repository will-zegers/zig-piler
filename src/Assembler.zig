// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const Parser = @import("Parser.zig");
const Symbol = @import("Semantic/Symbols.zig");
const TAC = @import("TAC.zig");

// const Patcher = @import("Assembler/Patcher.zig");
const instruction = @import("Assembler/instruction.zig");
pub const Instruction = instruction.Instruction;
pub const Operand = instruction.Operand;
pub const Reg = instruction.Reg;
pub const Type = instruction.Type;
const ARG_REGISTERS = instruction.ARG_REGISTERS;
const LONGWORD_BYTES = instruction.LONGWORD_BYTES;
const QUADWORD_BYTES = instruction.QUADWORD_BYTES;
const Binary = instruction.Binary;
const InstructionList = instruction.InstructionList;
const Jmp = instruction.Jmp;
const JmpCC = instruction.JmpCC;
const Label = instruction.Label;
const Mov = instruction.Mov;
const Ret = instruction.Ret;
const Unary = instruction.Unary;

const Assembler = @This();

pub const Assembly = Program;

const Program = struct {
    allocator: Allocator,
    topLevel: []TopLevel,
    defined: StringHashMap(bool),

    pub fn deinit(self: *Assembly) void {
        for (self.topLevel) |*topLevel| {
            switch (topLevel.*) {
                .Function => |*function| function.deinit(),
                .StaticVariable => {},
            }
        }
        self.allocator.free(self.topLevel);
        self.defined.deinit();
    }
};

pub const Function = struct {
    allocator: Allocator,
    name: []const u8,
    global: bool,
    instructions: []Instruction,

    pub fn deinit(self: *Function) void {
        defer self.allocator.free(self.instructions);
    }
};

pub const StaticVariable = struct {
    type: Parser.Type,
    name: []const u8,
    global: bool,
    init: Symbol.StaticInit,
    alignment: usize,
};

const TopLevelTag = enum { Function, StaticVariable };
const TopLevel = union(TopLevelTag) {
    Function: Function,
    StaticVariable: StaticVariable,
};

pub fn assemble(allocator: Allocator, symbols: Symbol.Table, tree: TAC.Program) Assembly {
    var topLevelList: ArrayList(TopLevel) = .empty;
    var defined: StringHashMap(bool) = .init(allocator);

    for (tree.topLevel) |topLevel| {
        switch (topLevel) {
            .Function => {
                const assembly = assembleFunction(allocator, symbols, topLevel.Function, &defined);
                topLevelList.append(allocator, .{ .Function = assembly }) catch allocError();
            },
            .StaticVariable => |staticVar| {
                const entry = symbols.get(staticVar.identifier).?;
                topLevelList.append(allocator, .{ .StaticVariable = .{
                    .type = entry.type,
                    .name = staticVar.identifier,
                    .global = staticVar.global,
                    .alignment = switch (entry.type) {
                        .Int => 4,
                        .Long => 8,
                        .FunType => unreachable,
                    },
                    .init = staticVar.init,
                } }) catch allocError();
            },
        }
    }

    return .{
        .allocator = allocator,
        .topLevel = topLevelList.toOwnedSlice(allocator) catch allocError(),
        .defined = defined,
    };
}

// TODO: break this function up
pub fn assembleFunction(allocator: Allocator, symbols: Symbol.Table, function: TAC.Function, defined: *StringHashMap(bool)) Function {
    var instructionList: InstructionList = .empty;
    var pseudoMap: std.StringHashMap(isize) = .init(allocator);
    defer pseudoMap.deinit();

    defined.put(function.name, true) catch allocError();

    // Move register arguments into stack memory so as not to clobber callee-saved registers
    var i: usize = 0;
    while (i < function.params.len and i < ARG_REGISTERS.len) {
        const name = function.params[i].unique.?;
        const src: Operand = .{ .Reg = ARG_REGISTERS[i] };
        const dst: Operand = .{ .Pseudo = name };
        const t: Type = .fromVar(symbols, name);
        instructionList.append(allocator, .{ .Mov = .{ .type = t, .src = src, .dst = dst } }) catch allocError();

        i += 1;
    }

    // Since the stack args already exist in memory, add an entry to the pseudo
    // table for the already existing stack offsets
    var stackPointerOffset: isize = 2 * QUADWORD_BYTES; // return-address + caller base-pointer
    while (i < function.params.len) {
        pseudoMap.put(function.params[i].unique.?, stackPointerOffset) catch allocError();

        i += 1;
        stackPointerOffset += QUADWORD_BYTES;
    }

    // First pass to build Assembly AST
    for (function.body) |instr| {
        // TODO: try to eliminate the slice allocation
        const assembly = Instruction.assemble(allocator, symbols, instr);
        defer allocator.free(assembly);

        instructionList.appendSlice(allocator, assembly) catch allocError();
    }

    // Second pass, replace Pseudo registers with stack locations and prepend the prelude
    setupStack(allocator, symbols, &instructionList, &pseudoMap);

    // Find illegal instructions (see specifications in the Patcher module)
    const instructions = instructionList.toOwnedSlice(allocator) catch allocError();

    return .{
        .allocator = allocator,
        .name = function.name,
        .global = symbols.get(function.name).?.attrs.Fun.global,
        .instructions = instructions,
    };
}

fn setupStack(allocator: Allocator, symbols: Symbol.Table, instructions: *InstructionList, pseudoMap: *StringHashMap(isize)) void{
    var localStack: isize = 0;

    for (instructions.items) |*instr| {
        switch (instr.*) {
            .Mov => |*mov| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &mov.src);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &mov.dst);
            },
            .Unary => |*unary| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &unary.operand);
            },
            .Binary => |*binary| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &binary.src);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &binary.dst);
            },
            .Idiv => |*idiv| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &idiv.operand);
            },
            .Cmp => |*cmp| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &cmp.arg1);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &cmp.arg2);
            },
            .SetCC => |*setcc| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &setcc.operand);
            },
            .Push => |*push| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &push.operand);
            },
            else => {},
        }
    }

    // Make sure the stack is 16-byte aligned
    const stackSpace = 2 * 16 * @divCeil(@abs(localStack), 2 * 16);

    // Prepend the instructions with stack space allocation based on the number of
    // pseudo registers (i.e. local variables) replaced with memory
    instructions.insert(allocator, 0, .{ .Binary = .{
        .type = .Quad,
        .operator = .Sub,
        .src = .{ .Imm = stackSpace },
        .dst = .{ .Reg = .sp },
    } }) catch allocError();
}

/// Replace 'Psuedo' registers generated in the first pass with memory locations
/// on the stack
fn replaceIfPseudo(symbols: Symbol.Table, map: *std.StringHashMap(isize), stackPointer: *isize, operand: *Operand) void {
    if (operand.* == .Pseudo) {
        const key = operand.Pseudo;
        // If the pseudo register has not been mapped to a location on the stack,
        // map it to the location in the local stack space
        if (symbols.get(key)) |entry| {
            if (entry.attrs == .Static) {
                operand.* = . { .Data = key };
                return;
            }
        }

        if (map.get(key) == null) {
            stackPointer.* -= LONGWORD_BYTES;
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
