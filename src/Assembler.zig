// zig fmt: off
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;

const Parser = @import("Parser.zig");
const Symbol = @import("Semantic/Symbols.zig");
const TAC = @import("TAC.zig");

const Patcher = @import("Assembler/Patcher.zig");
const instruction = @import("Assembler/instruction.zig");
pub const Instruction = instruction.Instruction;
pub const Operand = instruction.Operand;
pub const Reg = instruction.Reg;
pub const StaticConstant = instruction.StaticConstant;
pub const StaticVariable = instruction.StaticVariable;
pub const Type = instruction.Type;
const ARG_INT_REGISTERS = instruction.ARG_INT_REGISTERS;
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
    Obj: struct { type: Type, isStatic: bool, isConstant: bool },
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
                .StaticConstant => |sc| {
                    self.allocator.free(sc.name);
                },
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

const TopLevelTag = enum { Function, StaticConstant, StaticVariable };
const TopLevel = union(TopLevelTag) {
    Function: Function,
    StaticConstant: StaticConstant,
    StaticVariable: StaticVariable,
};

pub fn assemble(allocator: Allocator, frontendSymbols: Symbol.Table, tree: TAC.Program) Assembly {
    var topLevelList: ArrayList(TopLevel) = .empty;
    var backendSymbols: StringHashMap(Entry) = .init(allocator);

    var staticConsts: AutoHashMap(u64, StaticConstant) = .init(allocator);
    defer staticConsts.deinit();

    var staticVars: ArrayList(TopLevel) = .empty;
    defer staticVars.deinit(allocator);

    for (tree.topLevel) |topLevel| {
        switch (topLevel) {
            .Function => |fun| {
                const assembly = assembleFunction(allocator, frontendSymbols, &staticConsts, topLevel.Function);
                topLevelList.append(allocator, .{ .Function = assembly }) catch allocError();

                // Function has been defined here, add an entry to the backend table
                backendSymbols.put(fun.name, .{ .Fun = .{ .defined = true } }) catch allocError();
            },
            .StaticVariable => |static| {
                // Static variables will be added to the end after .text. For now, just keep track of them
                const entry = frontendSymbols.get(static.identifier).?;
                const def: TopLevel =
                    .{ .StaticVariable = StaticVariable.init(entry.type, static) };
                staticVars.append(allocator, def) catch allocError();
            },
        }
    }

    // After all the .text section (functions and their instruction), add all static variables at the end
    for (staticVars.items) |item| {
        topLevelList.append(allocator, item) catch allocError();
    }

    var valueIt = staticConsts.valueIterator();
    while (valueIt.next()) |value_ptr| {
        topLevelList.append(allocator, .{ .StaticConstant = value_ptr.* }) catch allocError();
    }

    populateBackendSymbols(&backendSymbols, frontendSymbols, staticConsts);

    return .{
        .allocator = allocator,
        .topLevel = topLevelList.toOwnedSlice(allocator) catch allocError(),
        .symbols = backendSymbols,
    };
}

pub fn assembleFunction(allocator: Allocator, symbols: Symbol.Table, staticConsts: *AutoHashMap(u64, StaticConstant), function: TAC.Function) Function {
    var instructionList: ArrayList(Instruction) = .empty;

    var pseudoMap = initStack(allocator, symbols, &instructionList, function.params) catch allocError();
    defer pseudoMap.deinit();

    // First pass to build Assembly AST
    for (function.body) |instr| {
        const assembly = Instruction.assemble(allocator, symbols, staticConsts, instr);
        defer allocator.free(assembly);

        instructionList.appendSlice(allocator, assembly) catch allocError();
    }

    // Second pass, replace Pseudo registers with stack locations and prepend the stack allocation calculus
    convertPseudoToMemory(allocator, symbols, &instructionList, &pseudoMap) catch allocError();

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
        if (i < ARG_INT_REGISTERS.len) { // register arguments
            const name = param.unique.?;
            const src: Operand = .{ .Reg = ARG_INT_REGISTERS[i] };
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

fn convertPseudoToMemory(
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
                .Double, .Long, .ULong => {
                    stackPointer.* += QUADWORD_BYTES;
                    stackPointer.* = 8 * @divCeil(stackPointer.*, 8);
                },
                .FunType => unreachable,
            }
            try map.put(key, -stackPointer.*);
        }
        const value = map.get(key).?;
        operand.* = .{ .Stack = value };
    }
}

fn populateBackendSymbols(beSymbols: *StringHashMap(Entry), feSymbols: Symbol.Table, constants: AutoHashMap(u64, StaticConstant)) void {
    var symbolIt = feSymbols.iterator();
    while (symbolIt.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Skip backend symbols function entries that were defined in assembly
        if (beSymbols.contains(key)) continue;

        beSymbols.put(key, switch (value.type) {
            .Int, .UInt => switch (value.attrs) {
                .Static => .{ .Obj = .{ .type = .Long, .isStatic = true, .isConstant = false } },
                .Local => .{ .Obj = .{ .type = .Long, .isStatic = false, .isConstant = false } },
                .Fun => unreachable,
            },
            .Double, .Long, .ULong => switch (value.attrs) {
                .Static => .{ .Obj = .{ .type = .Quad, .isStatic = true, .isConstant = false } },
                .Local => .{ .Obj = .{ .type = .Quad, .isStatic = false, .isConstant = false } },
                .Fun => unreachable,
            },
            .FunType => .{ .Fun = .{ .defined = false } },
        }) catch allocError();
    }

    var constIt = constants.valueIterator();
    while (constIt.next()) |value_ptr| {
        const value = value_ptr.*;
        const key = value.name;

        beSymbols.put(key, switch (value.type) {
            .Long => .{ .Obj = .{ .type = .Long, .isStatic = true, .isConstant = true } },
            .Double, .Quad => .{ .Obj = .{ .type = .Quad, .isStatic = false, .isConstant = true } },
        }) catch allocError();
    }
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
