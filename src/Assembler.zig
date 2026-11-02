// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const Parser = @import("Parser.zig");
const Symbol = @import("Semantic/Symbols.zig");
const TAC = @import("TAC.zig");

const Patcher = @import("Assembler/Patcher.zig");
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

const EntryTag = enum {Obj, Fun};
pub const Entry = union(EntryTag) {
    Obj: struct { type: Type, isStatic: bool },
     Fun: struct { defined: bool },
};

const Program = struct {
    allocator: Allocator,
    topLevel: []TopLevel,
    symbols: StringHashMap(Entry),

    pub fn deinit(self: *Assembly) void {
        for (self.topLevel) |*topLevel| {
            switch (topLevel.*) {
                .Function => |*function| function.deinit(),
                .StaticVariable => {},
            }
        }
        self.allocator.free(self.topLevel);
        self.symbols.deinit();
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
    defer defined.deinit();

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

    var backendSymbols: StringHashMap(Entry) = .init(allocator);
    var it = symbols.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        backendSymbols.put(key, switch (value.type) {
            .FunType =>  .{ .Fun = .{ .defined = defined.get(key) orelse false } },
            .Int => switch (value.attrs) {
                .Static => .{ .Obj = .{ .type = .Long, .isStatic = true } },
                .Local => .{ .Obj = .{ .type = .Long, .isStatic = false } },
                .Fun => unreachable,
            },
            .Long => switch (value.attrs) {
                .Static => .{ .Obj = .{ .type = .Quad, .isStatic = true } },
                .Local => .{ .Obj = .{ .type = .Quad, .isStatic = false } },
                .Fun => unreachable,
            }
        }) catch allocError();
    }

    return .{
        .allocator = allocator,
        .topLevel = topLevelList.toOwnedSlice(allocator) catch allocError(),
        .symbols = backendSymbols,
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
        const assembly = Instruction.assemble(allocator, symbols, instr);
        defer allocator.free(assembly);

        instructionList.appendSlice(allocator, assembly) catch allocError();
    }

    // Second pass, replace Pseudo registers with stack locations and prepend the prelude
    setupStack(allocator, symbols, &instructionList, &pseudoMap);

    // Find illegal instructions (see specifications in the Patcher module)
    var instructions = instructionList.toOwnedSlice(allocator) catch allocError();
    instructions = Patcher.patchInstructions(allocator, instructions);


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
            .Binary => |*binary| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &binary.src);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &binary.dst);
            },
            .Cmp => |*cmp| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &cmp.arg1);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &cmp.arg2);
            },
            .Idiv => |*idiv| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &idiv.operand);
            },
            .Mov => |*mov| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &mov.src);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &mov.dst);
            },
            .Movsx => |*movsx| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &movsx.src);
                replaceIfPseudo(symbols, pseudoMap, &localStack, &movsx.dst);
            },
            .Push => |*push| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &push.operand);
            },
            .SetCC => |*setcc| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &setcc.operand);
            },
            .Unary => |*unary| {
                replaceIfPseudo(symbols, pseudoMap, &localStack, &unary.operand);
            },
            else => {},
        }
    }

    // Make sure the stack is 16-byte aligned
    const stackSpace = 16 * @divCeil(@abs(localStack), 16);

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
        const entry = symbols.get(key).?;

        // Map static variables to .Data segment
        if (entry.attrs == .Static) {
            operand.* = .{ .Data = key };
            return;
        }

        // If the pseudo register has not been mapped to a location on the stack,
        // map it to the location in the local stack space
        if (map.get(key) == null) {
            switch (entry.type) {
                .Int => {
                    stackPointer.* -= LONGWORD_BYTES;
                },
                .Long => {
                    stackPointer.* -= QUADWORD_BYTES;
                    while (@rem(stackPointer.*, 8) != 0) {
                        stackPointer.* -= 1;
                    }
                    // stackPointer.* = @divCeil(@abs(stackPointer.*), 8); // align to 8-bytes
                },
                .FunType => unreachable,
            }
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
