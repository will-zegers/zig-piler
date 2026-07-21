const std = @import("std");
const Allocator = std.mem.Allocator;

const Patcher = @This();

const instructions = @import("instruction.zig");
const Instructions = instructions.Instructions;
const Cmp = instructions.Cmp;
const Mov = instructions.Mov;
const Binary = instructions.Binary;
const Idiv = instructions.Idiv;
const Instruction = instructions.Instruction;

const IllegalInstruction = enum {
    Ill_Binary_Operands,
    Ill_Cmp_Operands,
    Ill_Cmp_Imm_Dst,
    Ill_Idiv_Operand,
    Ill_Mov_Operands,
    Ill_Mul_Mem_Dst,
    Ill_Shift_Rcx,
};

pub fn patchInstructions(allocator: Allocator, unpatched: *Instructions) Instructions {
    var patched: Instructions = .empty;

    for (unpatched.items) |instr| {
        if (Patcher.detectIllegal(instr)) |illegal| {
            const patch = switch (illegal) {
                .Ill_Binary_Operands => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Binary.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Binary = .{ .operator = instr.Binary.operator, .src = .{ .Reg = .r10 }, .dst = instr.Binary.dst } },
                }),
                .Ill_Cmp_Imm_Dst => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Cmp.arg2, .dst = .{ .Reg = .r11 } } },
                    .{ .Cmp = .{ .arg1 = instr.Cmp.arg1, .arg2 = .{ .Reg = .r11 } } },
                }),
                .Ill_Cmp_Operands => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Cmp.arg1, .dst = .{ .Reg = .r10 } } },
                    .{ .Cmp = .{ .arg1 = .{ .Reg = .r10 }, .arg2 = instr.Cmp.arg2 } },
                }),
                .Ill_Mov_Operands => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Mov.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Mov = .{ .src = .{ .Reg = .r10 }, .dst = instr.Mov.dst } },
                }),
                .Ill_Mul_Mem_Dst => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Binary.dst, .dst = .{ .Reg = .r11 } } },
                    .{ .Binary = .{ .operator = instr.Binary.operator, .src = instr.Binary.src, .dst = .{ .Reg = .r11 } } },
                    .{ .Mov = .{ .src = .{ .Reg = .r11 }, .dst = instr.Binary.dst } },
                }),
                .Ill_Idiv_Operand => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Idiv.operand, .dst = .{ .Reg = .r10 } } },
                    .{ .Idiv = .{ .operand = .{ .Reg = .r10 } } },
                }),
                .Ill_Shift_Rcx => allocator.dupe(Instruction, &.{
                    .{ .Mov = .{ .src = instr.Binary.src, .dst = .{ .Reg = .rcx } } },
                    .{ .Binary = .{ .operator = instr.Binary.operator, .src = .{ .Reg = .rcx }, .dst = instr.Binary.dst } },
                }),
            } catch allocError();
            defer allocator.free(patch);

            patched.appendSlice(allocator, patch) catch allocError();
        } else {
            patched.append(allocator, instr) catch allocError();
        }
    }
    unpatched.deinit(allocator);

    return patched;
}

fn detectIllegal(instr: Instruction) ?IllegalInstruction {
    switch (instr) {
        .Mov => |mov| if (isIllegalMove(mov)) return .Ill_Mov_Operands,
        .Idiv => |idiv| if (isIllegalIdiv(idiv)) return .Ill_Idiv_Operand,
        .Binary => |bin| {
            if (isIllegalMul(bin)) return .Ill_Mul_Mem_Dst;
            if (isIllegalShift(bin)) return .Ill_Shift_Rcx;
            if (isIllegalBinary(bin)) return .Ill_Binary_Operands;
        },
        .Cmp => |cmp| {
            if (isIllegalCmpOperands(cmp)) return .Ill_Cmp_Operands;
            if (isIllegalCmpImmDst(cmp)) return .Ill_Cmp_Imm_Dst;
        },
        else => {},
    }
    return null;
}

// Mov may not have memory (i.e. stack) as both its source and destination
fn isIllegalMove(mov: Mov) bool {
    return mov.dst == .Stack and mov.src == .Stack;
}

// Operand of idiv must not be an immediate value
fn isIllegalIdiv(idiv: Idiv) bool {
    return idiv.operand == .Imm;
}

// Destination of mul or shifts must not be a memory address
fn isIllegalMul(bin: Binary) bool {
    return bin.operator == .Mul and bin.dst == .Stack;
}

fn isIllegalShift(bin: Binary) bool {
    return (bin.operator == .SAL or bin.operator == .SAR) and bin.dst == .Stack;
}

// Add, sub, and cmp must not have memory as both its source and destination
fn isIllegalBinary(bin: Binary) bool {
    return bin.src == .Stack and bin.dst == .Stack;
}

// Add and sub must not have memory as both its source and destination
fn isIllegalCmpOperands(cmp: Cmp) bool {
    return cmp.arg1 == .Stack and cmp.arg2 == .Stack;
}

// Add and sub must not have memory as both its source and destination
fn isIllegalCmpImmDst(cmp: Cmp) bool {
    return cmp.arg2 == .Imm;
}

fn allocError() noreturn {
    @panic("Memory allocation error");
}
