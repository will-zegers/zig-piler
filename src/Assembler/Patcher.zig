const std = @import("std");
const Allocator = std.mem.Allocator;

const Patcher = @This();

const instructions = @import("instruction.zig");
const InstructionList = instructions.InstructionList;
const Cmp = instructions.Cmp;
const Mov = instructions.Mov;
const Binary = instructions.Binary;
const Idiv = instructions.Idiv;
const Instruction = instructions.Instruction;
const Operand = instructions.Operand;

const IllegalInstruction = enum {
    Ill_Binary_Operands,
    Ill_Cmp_Operands,
    Ill_Cmp_Imm_Dst,
    Ill_Idiv_Operand,
    Ill_Mov_Operands,
    Ill_Mul_Mem_Dst,
    Ill_Shift_Rcx,
};

pub fn patchInstructions(allocator: Allocator, unpatched: []Instruction) []Instruction {
    var patched: InstructionList = .empty;

    for (unpatched) |instr| {
        if (Patcher.detectIllegal(instr)) |illegal| {
            patched.appendSlice(allocator, switch (illegal) {
                // Binary operations must not have memory as both its source and destination.
                // Move the 'src' intro a temporary register first, then proceed with the operation
                .Ill_Binary_Operands => &.{
                    .{ .Mov = .{ .src = instr.Binary.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Binary = .{ .operator = instr.Binary.operator, .src = .{ .Reg = .r10 }, .dst = instr.Binary.dst } },
                },
                // The second argument of a 'cmp' instruction must not be a constant (i.e. immediate value)
                // Move the immediate value into a temporary register prior to the operation
                .Ill_Cmp_Imm_Dst => &.{
                    .{ .Mov = .{ .src = instr.Cmp.arg2, .dst = .{ .Reg = .r11 } } },
                    .{ .Cmp = .{ .arg1 = instr.Cmp.arg1, .arg2 = .{ .Reg = .r11 } } },
                },
                // Comparison 'cmp' instructions must not have both args as memory addresses
                // Move the first arg into a temporary register first, then compare
                .Ill_Cmp_Operands => &.{
                    .{ .Mov = .{ .src = instr.Cmp.arg1, .dst = .{ .Reg = .r10 } } },
                    .{ .Cmp = .{ .arg1 = .{ .Reg = .r10 }, .arg2 = instr.Cmp.arg2 } },
                },
                // Operand (i.e. the divisor) of idiv must not be an immediate value
                // Move the immediate value into a temporary register prior to the operation
                .Ill_Idiv_Operand => &.{
                    .{ .Mov = .{ .src = instr.Idiv.operand, .dst = .{ .Reg = .r10 } } },
                    .{ .Idiv = .{ .operand = .{ .Reg = .r10 } } },
                },
                // Mov may not have memory (i.e. stack) as both its source and destination
                // Move the 'src' intro a temporary register first, then proceed with the operation
                .Ill_Mov_Operands => &.{
                    .{ .Mov = .{ .src = instr.Mov.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Mov = .{ .src = .{ .Reg = .r10 }, .dst = instr.Mov.dst } },
                },
                // Multiply instructions must not have the destination as a memory address (i.e. stack)
                // Move the 'dst' into a temporary register first, carry out the operation, and
                // move the result in the temporary back to the original 'dst' memory address
                .Ill_Mul_Mem_Dst => &.{
                    .{ .Mov = .{ .src = instr.Binary.dst, .dst = .{ .Reg = .r11 } } },
                    .{ .Binary = .{ .operator = instr.Binary.operator, .src = instr.Binary.src, .dst = .{ .Reg = .r11 } } },
                    .{ .Mov = .{ .src = .{ .Reg = .r11 }, .dst = instr.Binary.dst } },
                },
                // Shift instructions must not have the destination as a memory address (i.e. stack). The
                // 'count' operand (i.e. amount to shift) should either be an immediate or stored in the CL
                // register, which is masked to 5-bits (32-bit register) or 6-bits (64-bit)
                .Ill_Shift_Rcx => &.{
                    .{ .Mov = .{ .src = instr.Binary.src, .dst = .{ .Reg = .cx } } },
                    .{ .Binary = .{ .operator = instr.Binary.operator, .src = .{ .Reg = .cl }, .dst = instr.Binary.dst } },
                },
            }) catch allocError();
        } else {
            patched.append(allocator, instr) catch allocError();
        }
    }
    allocator.free(unpatched);

    return patched.toOwnedSlice(allocator) catch allocError();
}

fn detectIllegal(instr: Instruction) ?IllegalInstruction {
    switch (instr) {
        .Binary => |bin| {
            // Order is important here, since an illegal binary instruction is more
            // general than an illegal mul. So specific cases should come first
            if (isIllegalMul(bin)) return .Ill_Mul_Mem_Dst;
            if (isIllegalShift(bin)) return .Ill_Shift_Rcx;
            if (isIllegalBinary(bin)) return .Ill_Binary_Operands;
        },
        .Cmp => |cmp| {
            if (isIllegalCmpImmDst(cmp)) return .Ill_Cmp_Imm_Dst;
            if (isIllegalCmpOperands(cmp)) return .Ill_Cmp_Operands;
        },
        .Idiv => |idiv| if (isIllegalIdiv(idiv)) return .Ill_Idiv_Operand,
        .Mov => |mov| if (isIllegalMove(mov)) return .Ill_Mov_Operands,
        else => return null,
    }
    return null;
}

// Check if the operand lies in either the stack or static memory space
fn isMemoryAddress(operand: Operand) bool {
    return operand == .Data or operand == .Stack;
}

// Binary operations must not have memory as both its source and destination
fn isIllegalBinary(bin: Binary) bool {
    return isMemoryAddress(bin.src) and isMemoryAddress(bin.dst);
}

// The second argument of a 'cmp' instruction must not be a constant (i.e. immediate value)
fn isIllegalCmpImmDst(cmp: Cmp) bool {
    return cmp.arg2 == .Imm;
}

// Comparison 'cmp' instructions must not have both args as memory addresses
fn isIllegalCmpOperands(cmp: Cmp) bool {
    return isMemoryAddress(cmp.arg1) and isMemoryAddress(cmp.arg2);
}

// Operand of idiv must not be an immediate value
fn isIllegalIdiv(idiv: Idiv) bool {
    return idiv.operand == .Imm;
}

// Mov may not have memory (i.e. stack or data/bss) as both its source and destination
fn isIllegalMove(mov: Mov) bool {
    return isMemoryAddress(mov.src) and isMemoryAddress(mov.dst);
}

// Multiply instructions must not have the destination as a memory address (i.e. stack)
fn isIllegalMul(bin: Binary) bool {
    return bin.operator == .Mul and isMemoryAddress(bin.dst);
}

// Shift instructions must not have the destination as a memory address (i.e. stack)
fn isIllegalShift(bin: Binary) bool {
    return (bin.operator == .SAL or bin.operator == .SAR) and isMemoryAddress(bin.dst);
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
