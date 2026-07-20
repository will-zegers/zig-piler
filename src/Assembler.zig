// zig fmt: off
const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const TAC = @import("TAC.zig");

const Assembler = @This();

pub const AST = Program;

const Instructions = ArrayList(Instruction);

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
        // Second pass, replace Pseudo registers with stack locations
        const stackPointer = assignStackLocations(allocator, &instructions);

        // Insert stack pointer arithmetic at the start
        AllocStack.prepend(allocator, stackPointer, &instructions);

        // Find illegal instructions (see specifications in the Instruction struct)
        fixIllegalInstructions(allocator, &instructions);

        return .{ .allocator = allocator, .name = function.name, .instructions = instructions, };
    }

    fn assignStackLocations(allocator: Allocator, instructions: *Instructions) isize {
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
                .Binary => |*binary| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &binary.src);
                    replaceIfPseudo(&pseudoMap, &stackCounter, &binary.dst);
                },
                .Idiv => |*idiv| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &idiv.operand);
                },
                .Cmp => |*cmp| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &cmp.arg1);
                    replaceIfPseudo(&pseudoMap, &stackCounter, &cmp.arg2);
                },
                .SetCC => |*setcc| {
                    replaceIfPseudo(&pseudoMap, &stackCounter, &setcc.operand);
                },
                else => {},
            }
        }
        return stackCounter;
    }

    fn fixIllegalInstructions(allocator: Allocator, instructions: *Instructions) void {
        var fixedInstructions: Instructions = .empty;

        for (instructions.items) |instr| {
            if (instr.detectIllegal()) |illegal| {
                switch (illegal) {
                    .Ill_Mov_Operands => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Mov.src, .dst = .{ .Reg = .r10 } } },
                                .{ .Mov = .{.src = .{ .Reg = .r10 }, .dst = instr.Mov.dst } },
                            }
                        ) catch std.process.exit(1);
                    },
                    .Ill_Binary_Operands => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Binary.src, .dst = .{ .Reg = .r10 } } },
                                .{ .Binary = .{.operator = instr.Binary.operator, .src = .{ .Reg = .r10 }, .dst = instr.Binary.dst } },
                            }
                        ) catch std.process.exit(1);
                    },
                    .Ill_Cmp_Operands => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Cmp.arg1, .dst = .{ .Reg = .r10 } } },
                                .{ .Cmp = .{.arg1 = .{ .Reg = .r10 }, .arg2 = instr.Cmp.arg2 } },
                            }
                        ) catch std.process.exit(1);
                    },
                    .Ill_Cmp_Imm_Dst => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Cmp.arg2, .dst = .{ .Reg = .r11 } } },
                                .{ .Cmp = .{.arg1 = instr.Cmp.arg1, .arg2 = . { .Reg = .r11 } } },
                            }
                        ) catch std.process.exit(1);
                    },
                    .Ill_Idiv_Operand => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Idiv.operand, .dst = .{ .Reg = .r10 } } },
                                .{ .Idiv = .{ .operand = .{ .Reg = .r10 } } },
                            }
                        ) catch std.process.exit(1);
                    },
                    .Ill_Mul_Mem_Dst => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Binary.dst, .dst = .{ .Reg = .r11 } } },
                                .{ .Binary = .{.operator = instr.Binary.operator, .src = instr.Binary.src, .dst = .{ .Reg = .r11 } } },
                                .{ .Mov = .{.src = .{ .Reg = .r11 }, .dst = instr.Binary.dst } },
                            }
                        ) catch std.process.exit(1);
                    },
                    .Ill_Shift_Rcx => {
                        fixedInstructions.appendSlice(
                            allocator,
                            &.{
                                .{ .Mov = .{.src = instr.Binary.src, .dst = .{ .Reg = .rcx } } },
                                .{ .Binary = .{.operator = instr.Binary.operator, .src = .{ .Reg = .rcx }, .dst = instr.Binary.dst } },
                            }
                        ) catch std.process.exit(1);
                    },
                }
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
                stackCounter.* -= WORD_SIZE;
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
    Binary,
    Cqo,
    Idiv,
    Cmp,
    Jmp,
    JmpCC,
    SetCC,
    Label,
};
const Instruction = union(InstructionTag) {
    Mov: Mov,
    Ret: Ret,
    Unary: Unary,
    AllocStack: AllocStack,
    Binary: Binary,
    Cqo: Cqo,
    Idiv: Idiv,
    Cmp: Cmp,
    Jmp: Jmp,
    JmpCC: JmpCC,
    SetCC: SetCC,
    Label: Label,

    const Illegal = enum {
        Ill_Binary_Operands,
        Ill_Cmp_Operands,
        Ill_Cmp_Imm_Dst,
        Ill_Idiv_Operand,
        Ill_Mov_Operands,
        Ill_Mul_Mem_Dst,
        Ill_Shift_Rcx,
    };

    // Helper functions to detect illegal operation that need remediation
    pub fn detectIllegal(self: Instruction) ?Illegal {
        if (self.isIllegalMove()) return .Ill_Mov_Operands;
        if (self.isIllegalIdiv()) return .Ill_Idiv_Operand;
        if (self.isIllegalMul()) return .Ill_Mul_Mem_Dst;
        if (self.isIllegalShift()) return .Ill_Shift_Rcx;
        if (self.isIllegalBinary()) return .Ill_Binary_Operands;
        if (self.isIllegalCmpOperands()) return .Ill_Cmp_Operands;
        if (self.isIllegalCmpImmDst()) return .Ill_Cmp_Imm_Dst;
        return null;
    }

    // Mov may not have memory (i.e. stack) as both its source and destination
    fn isIllegalMove(self: Instruction) bool {
        return self.isMov() and (self.Mov.dst.isStack() and self.Mov.src.isStack());
    }

    // Operand of idiv must not be an immediate value
    fn isIllegalIdiv(self: Instruction) bool {
        return self == Instruction.Idiv and self.Idiv.operand.isImm();
    }

    // Destination of mul or shifts must not be a memory address
    fn isIllegalMul(self: Instruction) bool {
        return self.isBinaryMul() and self.Binary.dst == .Stack;
    }

    fn isIllegalShift(self: Instruction) bool {
        return self.isBinaryShift() and self.Binary.src != .Imm;
    }

    // Add, sub, and cmp must not have memory as both its source and destination
    fn isIllegalBinary(self: Instruction) bool {
        return self.isBinary() and (self.Binary.src.isStack() and self.Binary.dst.isStack());
    }

    // Add and sub must not have memory as both its source and destination
    fn isIllegalCmpOperands(self: Instruction) bool {
        return self == Instruction.Cmp and (self.Cmp.arg1.isStack() and self.Cmp.arg2.isStack());
    }

    // Add and sub must not have memory as both its source and destination
    fn isIllegalCmpImmDst(self: Instruction) bool {
        return self == Instruction.Cmp and self.Cmp.arg2.isImm();
    }

    fn isMov(self: Instruction) bool {
        return self == Instruction.Mov;
    }

    pub fn isBinary(self: Instruction) bool {
        return self == Instruction.Binary;
    }

    fn isBinaryMul(self: Instruction) bool {
        return self.isBinary() and self.Binary.operator == .Mul;
    }

    fn isBinaryShift(self: Instruction) bool {
        return self.isBinary() and (self.Binary.operator == .SAL or self.Binary.operator == .SAR);
    }

    fn isBinaryAddSub(self: Instruction) bool {
        return self.isBinary() and (self.Binary.operator == .Add or self.Binary.operator == .Sub);
    }
};



pub const Mov = struct {
    src: Operand,
    dst: Operand,

    pub fn append(allocator: Allocator, instructions: *Instructions, copy: TAC.Copy) void {
        const src: Operand = switch(copy.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        const dst: Operand = switch(copy.dst) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        instructions.append(allocator, .{ .Mov = .{ .src = src, .dst = dst } }) catch std.process.exit(1);
    }
};

pub const Ret = struct {
    pub fn append(allocator: Allocator, instructions: *Instructions, ret: TAC.Return) void {
        const val: Operand = switch(ret.val) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo },
        };

        instructions.appendSlice(
            allocator,
            &.{
                .{ .Mov = .{.src = val, .dst = .{ .Reg = .rax } } },
                .{ .Ret = .{} },
            },
        ) catch std.process.exit(1);
    }
};

pub const Unary = struct {
    pub const Operator = TAC.Unary.Operator;

    operator: Operator,
    operand: Operand,

    pub fn append(allocator: Allocator, instructions: *Instructions, unary: TAC.Unary) void {
        const src: Operand = switch(unary.src) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        const dst: Operand = .{ .Pseudo = unary.dst.Var };
        const instrSlice = switch (unary.operator) {
            .Not => blk: {
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{.arg1 = .{ .Imm = "0" }, .arg2 = src } },
                    .{ .Mov = .{.src = .{ .Imm = "0" }, .dst = dst } },
                    .{ .SetCC = .{ .condition = .E, .operand = dst } },
                }) catch std.process.exit(1);
            },
            else => blk: {
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{.src = src, .dst = .{ .Pseudo = unary.dst.Var } } },
                    .{ .Unary = .{.operator = unary.operator, .operand = dst } },
                }) catch std.process.exit(1);
            },
        };
        defer allocator.free(instrSlice);
        instructions.appendSlice(allocator, instrSlice) catch std.process.exit(1);
    }
};

pub const AllocStack = struct {
    stackPointer: isize,

    pub fn prepend(allocator: Allocator, stackPointer: isize, instructions: *Instructions) void {
        instructions.insert(allocator, 0, .{ .AllocStack = .{ .stackPointer = stackPointer } }) catch std.process.exit(0);
    }
};

pub const Binary = struct {
    const Operator = TAC.Binary.Operator;

    operator: Operator,
    src: Operand,
    dst: Operand,

    pub fn append(allocator: Allocator, instructions: *Instructions, binary: TAC.Binary) void {
        const src1: Operand = switch(binary.src1) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        const src2: Operand = switch(binary.src2) {
            .Constant => |constant| .{ .Imm = constant },
            .Var => |pseudo| .{ .Pseudo = pseudo},
        };
        const dst: Operand = .{ .Pseudo = binary.dst.Var };

        const instruction = switch (binary.operator) {
            .Div, .Mod, => blk: {
                const sourceReg: Operand = switch(binary.operator) {
                    .Div => .{ .Reg = .rax },
                    .Mod => .{ .Reg = .rdx },
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src1, .dst = .{ .Reg = .rax } } },
                    .{ .Cqo = .{} },
                    .{ .Idiv = .{.operand = src2 } },
                    .{ .Mov = .{ .src = sourceReg, .dst = dst } },
                }) catch std.process.exit(1);
            },
            .Eq, .Gt, .Gte, .Lt, .Lte, .Neq => |op| blk: {
                const cCode: ConditionCode = switch (op) {
                    .Eq => .E,
                    .Gt => .G,
                    .Gte => .GE,
                    .Lt => .L,
                    .Lte => .LE,
                    .Neq => .NE,
                    else => unreachable,
                };
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Cmp = .{ .arg1 = src2, .arg2 = src1 } },
                    .{ .Mov = .{ .src = .{.Imm = "0"}, .dst = dst  } },
                    .{ .SetCC = .{ .condition = cCode, .operand = dst } },
                }) catch std.process.exit(1);
            },
            .AndL, .OrL => unreachable, // logical AND and OR should not have a binary instruction
            else => blk: {
                break :blk allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = src1, .dst = dst } },
                    .{ .Binary = .{ .operator = binary.operator, .src = src2, .dst = dst } },
                }) catch std.process.exit(1);
            },
        };
        defer allocator.free(instruction);

        instructions.appendSlice(allocator, instruction) catch std.process.exit(1);
    }
};

pub const Cqo = struct {};

pub const Idiv = struct { operand: Operand };

pub const Cmp = struct{
    arg1: Operand,
    arg2: Operand,
};

pub const Jmp = struct {
    target: Identifier,

        pub fn append(allocator: Allocator, instructions: *Instructions, jmp: TAC.Jump) void {
            instructions.append(allocator, .{
                .Jmp = .{ .target = jmp.target }
            }) catch std.process.exit(1);
        }
};

pub const JmpCC = struct {
    condition: ConditionCode,
    target: Identifier,

    pub fn append(allocator: Allocator, instructions: *Instructions, jmpInstr: TAC.Instruction) void {
        switch (jmpInstr) {
            .JumpIfZero => |jz| {
                const arg2: Operand = switch (jz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                instructions.appendSlice(allocator, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .E, .target = jz.target } },
                }) catch std.process.exit(1);
            },
            .JumpIfNotZero => |jnz| {
                const arg2: Operand = switch (jnz.condition) {
                    .Constant => |constant| .{ .Imm = constant },
                    .Var => |pseudo| .{ .Pseudo = pseudo },
                };
                instructions.appendSlice(allocator, &.{
                    .{ .Cmp = .{ .arg1 = .{ .Imm = "0" }, .arg2 = arg2 } },
                    .{ .JmpCC = .{ .condition = .NE, .target = jnz.target } },
                }) catch std.process.exit(1);
            },
            else => unreachable,
        }
    }
};

pub const SetCC = struct {condition: ConditionCode, operand: Operand};

pub const Label = struct {
    id: Identifier,

    pub fn append(allocator: Allocator, instructions: *Instructions, label: TAC.Label) void {
        instructions.append(allocator, .{ .Label = .{ .id = label.identifier } }) catch std.process.exit(1);
    }
};

const OperandType = enum {
    Imm,
    Reg,
    Pseudo,
    Stack,
};
pub const Operand = union(OperandType) {
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

    pub fn isImm(self: Operand) bool {
        return self == Operand.Imm;
    }
};

pub const Reg = enum {
    rax,
    al,
    rcx,
    cl,
    rdx,
    dl,
    r10,
    r10b,
    r11,
    r11b,

    pub fn toByteRegister(operand: Assembler.Operand) Assembler.Operand {
        return switch (operand) {
            .Reg => |reg| switch(reg) {
                .rax => .{ .Reg = .al},
                .rcx => .{ .Reg = .cl},
                .rdx => .{ .Reg = .dl},
                .r10 => .{ .Reg = .r10b},
                .r11 => .{ .Reg = .r11b},
                else => operand,
            },
            else => operand,
        };
    }
};

const Identifier = []const u8;

const ConditionCode = enum { E, G, GE, L, LE, NE, };
