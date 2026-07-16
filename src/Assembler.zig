// zig fmt: off
const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const TAC = @import("TAC.zig");

const Assembler = @This();

pub const AST = Program;

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
    instructions: ArrayList(Instruction),

    pub fn init(allocator: Allocator, function: TAC.Function) Function {
        var instructions: ArrayList(Instruction) = .empty;

        // First pass to build Assembly AST
        for (function.body.items) |instr| {
            switch (instr) {
                .Unary => |unary| Unary.append(allocator, &instructions, unary),
                .Return => |ret| Ret.append(allocator, &instructions, ret),
            }
        }
        // Second pass, replace Pseudo registers with stack locations
        const stackPointer = assignStackLocations(allocator, &instructions);

        // Insert stack pointer arithmetic at the start
        instructions.insert(allocator, 0, AllocStack.init(stackPointer)) catch std.process.exit(0);

        // Find illegal (i.e. memory-to-memory) moves; split them into memory-to-register-memory moves
        fixMoves(allocator, &instructions);

        return .{ .allocator = allocator, .name = function.name, .instructions = instructions, };
    }

    fn assignStackLocations(allocator: Allocator, instructions: *ArrayList(Instruction)) isize {
        var pseudoMap: std.StringHashMap(isize) = .init(allocator);
        defer pseudoMap.deinit();
        var stackCounter: isize = -4;

        for (instructions.items) |*instruction| {
            switch (instruction.*) {
                .Mov => |*mov| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &mov.src);
                    replaceIfPseudo(&pseudoMap, &stackCounter, &mov.dst);
                },
                .Unary => |*unary| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &unary.operand);
                },
                else => {},
            }
        }
        return stackCounter;
    }

    fn fixMoves(allocator: Allocator, instructions: *ArrayList(Instruction)) void {
        var fixedInstructions: ArrayList(Instruction) = .empty;

        for (instructions.items) |instr| {
            if (instr.isIllegalMove()) {
                fixedInstructions.appendSlice(
                    allocator,
                    &.{
                        .{ .Mov = .{.src = instr.Mov.src, .dst = .{ .Reg = .R10 } } },
                        .{ .Mov = .{.src = .{ .Reg = .R10 }, .dst = instr.Mov.dst } },
                    }
                ) catch std.process.exit(1);
            } else {
                fixedInstructions.append(allocator, instr) catch std.process.exit(1);
            }
        }
        instructions.clearAndFree(allocator);
        instructions.* = fixedInstructions;
    }

    fn replaceIfPseudo(map: *std.StringHashMap(isize), stackCounter: *isize, operand: *Operand) void {
        if (operand.*.isPseudo()) {
            const key = operand.*.Pseudo;
            if (map.get(key) == null) {
                map.put(key, stackCounter.*) catch std.process.exit(1);
                stackCounter.* -= 4;
            }
            const value = map.get(key).?;
            operand.* = .{ .Stack = value };
        }
    }

    pub fn deinit(self: *Function) void {
        defer self.instructions.deinit(self.allocator);
    }
};

const InstructionTag = enum {
    Mov,
    Ret,
    Unary,
    AllocStack,
};
const Instruction = union(InstructionTag) {
    Mov: Mov,
    Ret: Ret,
    Unary: Unary,
    AllocStack: AllocStack,

    pub fn isMov(self: Instruction) bool {
        return self == Instruction.Mov;
    }

    pub fn isIllegalMove(self: Instruction) bool {
        return self.isMov() and (self.Mov.dst.isStack() and self.Mov.src.isStack());
    }
};

pub const Mov = struct {
    src: Operand,
    dst: Operand,
};

pub const Ret = struct {
    pub fn append(allocator: Allocator, instructions: *ArrayList(Instruction), ret: TAC.Return) void {
        const val: Operand = switch(ret.val) {
            .Constant => |constant| .{ .Imm = constant.int },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };

        instructions.appendSlice(
            allocator,
            &.{
                .{ .Mov = .{.src = val, .dst = .{ .Reg = .AX } } },
                .{ .Ret = .{} },
            },
        ) catch std.process.exit(1);
    }
};

pub const Unary = struct {
    operator: Parser.Unary.Operator,
    operand: Operand,

    pub fn append(allocator: Allocator, instructions: *ArrayList(Instruction), unary: TAC.Unary) void {
        const src: Operand = switch(unary.src) {
            .Constant => |constant| .{ .Imm = constant.int },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        const dst: Operand = .{ .Pseudo = unary.dst.Var };

        instructions.appendSlice(
            allocator, 
            &.{
                .{ .Mov = .{.src = src, .dst = .{ .Pseudo = unary.dst.Var } } },
                .{ .Unary = .{.operator = unary.operator, .operand = dst } },
            },
        ) catch std.process.exit(0);
    }
};

pub const AllocStack = struct {
    stackPointer: isize,

    pub fn init(stackPointer: isize) Instruction {
        return .{ .AllocStack = .{ .stackPointer = stackPointer } };
    }
};

const OperandType = enum {
    Imm,
    Reg,
    Pseudo,
    Stack,
};
const Operand = union(OperandType) {
    Imm: []const u8,
    Reg: Reg,
    Pseudo: []const u8,
    Stack: isize,

    pub fn isPseudo(self: Operand) bool {
        return self == Operand.Pseudo;
    }

    pub fn isStack(self: Operand) bool {
        return self == Operand.Stack;
    }
};

const Reg = enum { AX, R10};

