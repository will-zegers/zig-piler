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
    initial: Symbol.StaticInit,
    alignment: usize,

    pub fn init(varType: Parser.Type, staticVar: TAC.StaticVariable) StaticVariable {
        return .{
            .type = varType,
            .name = staticVar.identifier,
            .global = staticVar.global,
            .alignment = switch (varType) {
                .Int, .UInt => 4,
                .Double, .Long, .ULong => 8,
                .FunType => unreachable,
            },
            .initial = staticVar.initial,
        };
    }

    pub fn isZero(self: StaticVariable) bool {
        return switch (self.initial) {
            .double => self.initial.double == 0,
            .int => self.initial.int == 0,
            .uint => self.initial.uint == 0,
            .long => self.initial.long == 0,
            .ulong => self.initial.ulong == 0,
        };
    }
};

const TopLevelTag = enum { Function, StaticVariable };
const TopLevel = union(TopLevelTag) {
    Function: Function,
    StaticVariable: StaticVariable,
};

pub fn assemble(allocator: Allocator, frontendSymbols: Symbol.Table, tree: TAC.Program) Assembly {
    var topLevelList: ArrayList(TopLevel) = .empty;
    var backendSymbols: StringHashMap(Entry) = .init(allocator);

    for (tree.topLevel) |topLevel| {
        switch (topLevel) {
            .Function => |fun| {
                const assembly = assembleFunction(allocator, frontendSymbols, topLevel.Function);
                topLevelList.append(allocator, .{ .Function = assembly }) catch allocError();

                // Function has been defined here, add an entry to the backend table
                backendSymbols.put(fun.name, .{ .Fun = .{ .defined = true } }) catch allocError();
            },
            .StaticVariable => |staticVar| {
                const entry = frontendSymbols.get(staticVar.identifier).?;
                topLevelList.append(allocator, .{ .StaticVariable =
                    StaticVariable.init(entry.type, staticVar),
                } ) catch allocError();
            },
        }
    }
    populateBackendSymbols(&backendSymbols, frontendSymbols);

    return .{
        .allocator = allocator,
        .topLevel = topLevelList.toOwnedSlice(allocator) catch allocError(),
        .symbols = backendSymbols,
    };
}

// TODO: break this function up
pub fn assembleFunction(allocator: Allocator, symbols: Symbol.Table, function: TAC.Function) Function {
    var instructionList: ArrayList(Instruction) = .empty;

    var pseudoMap = initStack(allocator, symbols, &instructionList, function.params) catch allocError();
    defer pseudoMap.deinit();

    // First pass to build Assembly AST
    for (function.body) |instr| {
        const assembly = Instruction.assemble(allocator, symbols, instr);
        defer allocator.free(assembly);

        instructionList.appendSlice(allocator, assembly) catch allocError();
    }

    // Second pass, replace Pseudo registers with stack locations and prepend the prelude
    setupStack(allocator, symbols, &instructionList, &pseudoMap) catch allocError();

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

/// Move register arguments into stack memory so as not to clobber callee-saved registers; initializes
/// a mapping for pseudo registers for allocating local variables to the stack
fn initStack(
    allocator: Allocator,
    symbols: Symbol.Table,
    instructions: *ArrayList(Instruction),
    params: []Parser.VarDecl
) Allocator.Error!StringHashMap(isize) {
    var pseudoMap: StringHashMap(isize) = .init(allocator);

    var stackPointerOffset: isize = 2 * QUADWORD_BYTES; // return-address + caller base-pointer
    for (params, 0..) |param, i| {
        if (i < ARG_REGISTERS.len) { // register arguments
            const name = param.unique.?;
            const src: Operand = .{ .Reg = ARG_REGISTERS[i] };
            const dst: Operand = .{ .Pseudo = name };
            const t: Type = .fromVar(symbols, name);
            try instructions.append(allocator, .{ .Mov = .{ .type = t, .src = src, .dst = dst } });
        } else { // stack arguments
            // Since the stack args already exist in memory, add an entry to the pseudo
            // table for the already existing stack offsets
            try pseudoMap.put(param.unique.?, stackPointerOffset);
            stackPointerOffset += QUADWORD_BYTES;
        }
    }
    return pseudoMap;
}

fn setupStack(
    allocator: Allocator,
    symbols: Symbol.Table,
    instructions: *ArrayList(Instruction),
    pseudoMap: *StringHashMap(isize)
) Allocator.Error!void{
    var localStack: isize = 0;

    for (instructions.items) |*instr| {
        switch (instr.*) {
            .Binary => |*binary| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &binary.src);
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &binary.dst);
            },
            .Cmp => |*cmp| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &cmp.arg1);
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &cmp.arg2);
            },
            .Div => |*div| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &div.operand);
            },
            .Idiv => |*idiv| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &idiv.operand);
            },
            .Mov => |*mov| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &mov.src);
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &mov.dst);
            },
            .Movsx => |*movsx| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &movsx.src);
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &movsx.dst);
            },
            .Movzx => |*movzx| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &movzx.src);
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &movzx.dst);
            },
            .Push => |*push| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &push.operand);
            },
            .SetCC => |*setcc| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &setcc.operand);
            },
            .Unary => |*unary| {
                try replaceIfPseudo(symbols, pseudoMap, &localStack, &unary.operand);
            },
            else => {},
        }
    }

    // Make sure the stack is 16-byte aligned, per SYS V ABI
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
fn replaceIfPseudo(
    symbols: Symbol.Table,
    map: *std.StringHashMap(isize),
    stackPointer: *isize,
    operand: *Operand
) Allocator.Error!void {
    if (operand.* == .Pseudo) {
        const key = operand.Pseudo;
        const entry = symbols.get(key).?;

        // Map static variables to .Data segment
        if (entry.attrs == .Static) {
            operand.* = .{ .Data = key };
            return;
        }

        // If the pseudo register has not been mapped to a location on the stack,
        // map it to the next location in the local stack space and move the SP
        if (map.get(key) == null) {
            switch (entry.type) {
                .Int, .UInt => {
                    stackPointer.* += LONGWORD_BYTES;
                },
                .Long, .ULong => {
                    stackPointer.* += QUADWORD_BYTES;
                    stackPointer.* = 8 * @divCeil(stackPointer.*, 8);
                },
                .Double => unreachable, // this could probably be merge with longs
                .FunType => unreachable,
            }
            try map.put(key, -stackPointer.*);
        }
        const value = map.get(key).?;
        operand.* = .{ .Stack = value };
    }
}

fn populateBackendSymbols(beSymbols: *StringHashMap(Entry), feSymbols: Symbol.Table) void {
    var it = feSymbols.iterator();
    while (it.next()) |entry| {

        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Skip backend symbols function entries that were defined in assembly
        if (beSymbols.contains(key)) continue;

        beSymbols.put(key, switch (value.type) {
            .Double => unreachable,
            .Int, .UInt => switch (value.attrs) {
                .Static => .{ .Obj = .{ .type = .Long, .isStatic = true } },
                .Local => .{ .Obj = .{ .type = .Long, .isStatic = false } },
                .Fun => unreachable,
            },
            .Long, .ULong => switch (value.attrs) {
                .Static => .{ .Obj = .{ .type = .Quad, .isStatic = true } },
                .Local => .{ .Obj = .{ .type = .Quad, .isStatic = false } },
                .Fun => unreachable,
            },
            .FunType => .{ .Fun = .{ .defined = false } },
        }) catch allocError();
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
