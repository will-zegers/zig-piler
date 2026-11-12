const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

const Patcher = @This();

const instructions = @import("instruction.zig");
const InstructionList = instructions.InstructionList;
const Binary = instructions.Binary;
const Cmp = instructions.Cmp;
const Cvttsd2si = instructions.Cvttsd2si;
const Cvtsi2sd = instructions.Cvtsi2sd;
const Div = instructions.Div;
const Idiv = instructions.Idiv;
const Instruction = instructions.Instruction;
const Mov = instructions.Mov;
const Movsx = instructions.Movsx;
const Movzx = instructions.Movzx;
const Push = instructions.Push;
const Operand = instructions.Operand;

pub fn patchInstructions(allocator: Allocator, unpatched: []Instruction) []Instruction {
    var patched: InstructionList = .empty;

    for (unpatched) |instr| {
        if (Patcher.detectIllegal(instr)) |illegal| {
            // For a majority of these patches: if an instruction has an illegal first operand, move
            // it into register r10 and use it as the new operand. For illegal second operand
            // (typically 'dst' that represent a variable) move the value into register r11, execute
            // the instruction, and then move the contents of r11 back into the original second operand
            //
            const t = instr.getType().?;
            patched.appendSlice(allocator, switch (illegal) {
                // Binary operations must not have memory as both its source and destination, or
                // an immediate operand that cannot be represented in 4-bytes.
                .Ill_Binary_Double => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Binary.dst, .dst = .{ .Reg = .xmm15 } } },
                    .{ .Binary = .{ .type = t, .operator = instr.Binary.operator, .src = instr.Binary.src, .dst = .{ .Reg = .xmm15 } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .xmm15 }, .dst = instr.Binary.dst } },
                },
                .Ill_Binary_Operands => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Binary.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Binary = .{ .type = t, .operator = instr.Binary.operator, .src = .{ .Reg = .r10 }, .dst = instr.Binary.dst } },
                },
                // Comparison 'cmp' instructions must not have both args as memory addresses
                .Ill_Cmp_Operands => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Cmp.arg1, .dst = .{ .Reg = .r10 } } },
                    .{ .Mov = .{ .type = t, .src = instr.Cmp.arg2, .dst = .{ .Reg = .r11 } } },
                    .{ .Cmp = .{ .type = t, .arg1 = .{ .Reg = .r10 }, .arg2 = .{ .Reg = .r11 } } },
                },
                .Ill_Cmp_Double => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Cmp.arg2, .dst = .{ .Reg = .xmm15 } } },
                    .{ .Cmp = .{ .type = t, .arg1 = instr.Cmp.arg1, .arg2 = .{ .Reg = .xmm15 } } },
                },
                .Ill_Cvtsi2sd_Operands => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Cvtsi2sd.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Cvtsi2sd = .{ .type = t, .src = .{ .Reg = .r10 }, .dst = .{ .Reg = .xmm15 } } },
                    .{ .Mov = .{ .type = .Double, .src = .{ .Reg = .xmm15 }, .dst = instr.Cvtsi2sd.dst } },
                },
                .Ill_Cvttsd2si_Operands => &.{
                    .{ .Cvttsd2si = .{ .type = t, .src = instr.Cvttsd2si.src, .dst = .{ .Reg = .r11 } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .r11 }, .dst = instr.Cvttsd2si.dst } },
                },
                // Operand (i.e. the divisor) of idiv must not be an immediate value
                .Ill_Div_Operand => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Div.operand, .dst = .{ .Reg = .r10 } } },
                    .{ .Div = .{ .type = t, .operand = .{ .Reg = .r10 } } },
                },
                .Ill_Idiv_Operand => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Idiv.operand, .dst = .{ .Reg = .r10 } } },
                    .{ .Idiv = .{ .type = t, .operand = .{ .Reg = .r10 } } },
                },
                // Mov may not have memory (i.e. stack or data) as both its source and destination
                .Ill_Mov_Double => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Mov.src, .dst = .{ .Reg = .xmm14 } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .xmm14 }, .dst = instr.Mov.dst } },
                },
                .Ill_Mov_Operands => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Mov.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .r10 }, .dst = instr.Mov.dst } },
                },
                // Sign-extended moves ('movsx') must not have the destination as a memory address (i.e.
                // stack) or an immediate operand beyond the range that can be represented in 4-bytes.
                .Ill_Movsx_Operands => &.{
                    .{ .Mov = .{ .type = .Long, .src = instr.Movsx.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Mov = .{ .type = .Long, .src = instr.Movsx.dst, .dst = .{ .Reg = .r11 } } },
                    .{ .Movsx = .{ .type = .Quad, .src = .{ .Reg = .r10 }, .dst = .{ .Reg = .r11 } } },
                    .{ .Mov = .{ .type = .Quad, .src = .{ .Reg = .r11 }, .dst = instr.Movsx.dst } },
                },
                // Multiply instructions must not have the destination as a memory address (i.e. stack)
                // or an immediate operand beyond the range that can be represented in 4-bytes.
                .Ill_Mul_Operands => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Binary.src, .dst = .{ .Reg = .r10 } } },
                    .{ .Mov = .{ .type = t, .src = instr.Binary.dst, .dst = .{ .Reg = .r11 } } },
                    .{ .Binary = .{ .type = t, .operator = instr.Binary.operator, .src = .{ .Reg = .r10 }, .dst = .{ .Reg = .r11 } } },
                    .{ .Mov = .{ .type = t, .src = .{ .Reg = .r11 }, .dst = instr.Binary.dst } },
                },
                // Push operations cannot push immediate values that exceed what can be represented in
                // 4-bytes.
                .Ill_Push_Imm_Quad => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Push.operand, .dst = .{ .Reg = .r10 } } },
                    .{ .Push = .{ .operand = .{ .Reg = .r10 } } },
                },
                // Shift instructions must not have the destination as a memory address (i.e. stack). The
                // 'count' operand (i.e. amount to shift) should either be an immediate or stored in the
                // lower bytes of the CX register, which is masked to 5-bits (32-bit register) or 6-bits
                // (64-bit)
                .Ill_Shift_Rcx => &.{
                    .{ .Mov = .{ .type = t, .src = instr.Binary.src, .dst = .{ .Reg = .cx } } },
                    .{ .Binary = .{ .type = t, .operator = instr.Binary.operator, .src = .{ .Reg = .cl }, .dst = instr.Binary.dst } },
                },
            }) catch allocError();
        } else {
            patched.append(allocator, instr) catch allocError();
        }
    }
    allocator.free(unpatched);

    return patched.toOwnedSlice(allocator) catch allocError();
}

const IllegalInstruction = enum {
    Ill_Binary_Double,
    Ill_Binary_Operands,
    Ill_Cmp_Operands,
    Ill_Cmp_Double,
    Ill_Cvttsd2si_Operands,
    Ill_Cvtsi2sd_Operands,
    Ill_Div_Operand,
    Ill_Idiv_Operand,
    Ill_Mov_Double,
    Ill_Mov_Operands,
    Ill_Movsx_Operands,
    Ill_Mul_Operands,
    Ill_Push_Imm_Quad,
    Ill_Shift_Rcx,
};

fn detectIllegal(instr: Instruction) ?IllegalInstruction {
    switch (instr) {
        .Binary => |bin| {
            switch (bin.type) {
                .Double => {
                    if (isIllegalBinaryDouble(bin)) return .Ill_Binary_Double;
                },
                .Long, .Quad => {
                    // Order is important here, since an illegal binary instruction is more
                    // general than an illegal mul. So specific cases should come first
                    if (isIllegalMul(bin)) return .Ill_Mul_Operands;
                    if (isIllegalShift(bin)) return .Ill_Shift_Rcx;
                    if (isIllegalBinaryOperands(bin)) return .Ill_Binary_Operands;
                },
            }
        },
        .Cmp => |cmp| {
            if (isIllegalCmpDouble(cmp)) return .Ill_Cmp_Double;
            if (isIllegalCmp(cmp)) return .Ill_Cmp_Operands;
        },
        .Cvtsi2sd => |cvt| if (isIllegalCvtsi2sd(cvt)) return .Ill_Cvtsi2sd_Operands,
        .Cvttsd2si => |cvt| if (isIllegalCvttsd2si(cvt)) return .Ill_Cvttsd2si_Operands,
        .Div => |div| if (isIllegalDiv(div)) return .Ill_Div_Operand,
        .Idiv => |idiv| if (isIllegalIdiv(idiv)) return .Ill_Idiv_Operand,
        .Mov => |mov| {
            if (isIllegalMoveDouble(mov)) return .Ill_Mov_Double;
            if (isIllegalMove(mov)) return .Ill_Mov_Operands;
        },
        .Movsx => |movsx| if (isIllegalMovsxOperands(movsx)) return .Ill_Movsx_Operands,
        .Push => |push| if (isIllegalPushImmQuad(push)) return .Ill_Push_Imm_Quad,
        else => return null,
    }
    return null;
}

// Check if the operand lies in either the stack or static memory space
fn isMemoryAddress(operand: Operand) bool {
    return operand == .Data or operand == .Stack;
}

// Binary operations must not have memory as both its source and destination,
// or an immediate src that exceeds what can be represented in 4 bytes
fn isIllegalBinaryOperands(bin: Binary) bool {
    return isIllegalBinaryQuadword(bin) or (isMemoryAddress(bin.src) and isMemoryAddress(bin.dst));
}

fn isIllegalBinaryDouble(bin: Binary) bool {
    switch (bin.operator) {
        .Add, .Div, .Mul, .Sub, .Xor => {
            return bin.type == .Double and bin.dst != .Reg;
        },
        else => return false,
    }
}

// Binary instructions cannot handle immediate values that won't fit into 4 bytes
fn isIllegalBinaryQuadword(bin: Binary) bool {
    if (bin.type != .Quad) return false;

    return switch (bin.src) {
        .Imm => |imm| switch (bin.operator) {
            .Add, .Mul, .Sub, .AndB, .OrB, .Xor => return (imm > math.maxInt(i32)),
            else => false,
        },
        else => return false,
    };
}

fn isIllegalCmp(cmp: Cmp) bool {
    return cmp.type != .Double and isIllegalCmpImmDst(cmp) or isIllegalCmpOperands(cmp);
}

// The second operand of a 'cmp' instruction must not be a constant (i.e. immediate value)
fn isIllegalCmpImmDst(cmp: Cmp) bool {
    return cmp.arg2 == .Imm;
}

// Comparison 'cmp' instructions must not have both operands as memory addresses
fn isIllegalCmpOperands(cmp: Cmp) bool {
    return (isMemoryAddress(cmp.arg1) and isMemoryAddress(cmp.arg2)) or
        (cmp.arg1 == .Imm and cmp.arg1.Imm > math.maxInt(i32));
}

fn isIllegalCmpDouble(cmp: Cmp) bool {
    return cmp.type == .Double and cmp.arg2 != .Reg;
}

// Operand of div-type instructions must not be an immediate value
fn isIllegalDiv(div: Div) bool {
    return div.operand == .Imm;
}
fn isIllegalIdiv(idiv: Idiv) bool {
    return idiv.operand == .Imm;
}

fn isIllegalMove(mov: Mov) bool {
    return isIllegalMoveMemory(mov) or isIllegalMoveQuadImm(mov);
}

fn isIllegalMoveDouble(mov: Mov) bool {
    return mov.type == .Double and isIllegalMoveMemory(mov);
}

// Mov cannot move an 8-byte immediate into memory
fn isIllegalMoveQuadImm(mov: Mov) bool {
    return mov.src == .Imm and mov.src.Imm > math.maxInt(i32) and isMemoryAddress(mov.dst);
}

// Mov may not have memory (i.e. stack or data/bss) as both its source and destination
fn isIllegalMoveMemory(mov: Mov) bool {
    return isMemoryAddress(mov.src) and isMemoryAddress(mov.dst);
}

// Movsx cannot have an immeditate as its 'src' or memory location as 'dst'
fn isIllegalMovsxOperands(movsx: Movsx) bool {
    return movsx.src == .Imm or isMemoryAddress(movsx.dst);
}

fn isIllegalMul(bin: Binary) bool {
    return isIllegalMulImmQuad(bin) or isIllegalMulMemDst(bin);
}

// Multiply must no have an operand that exceeds what can be represented in 4-bytes
fn isIllegalMulImmQuad(bin: Binary) bool {
    return bin.operator == .Mul and bin.src == .Imm and bin.src.Imm > math.maxInt(i32);
}

// Multiply instructions must not have the destination as a memory address (i.e. stack)
fn isIllegalMulMemDst(bin: Binary) bool {
    return bin.operator == .Mul and isMemoryAddress(bin.dst);
}

// Push operand cannot be an immediate that can't be represented in 4-bytes
fn isIllegalPushImmQuad(push: Push) bool {
    return push.operand == .Imm and push.operand.Imm > math.maxInt(i32);
}

// Shift instructions must not have the destination as a memory address (i.e. stack)
fn isIllegalShift(bin: Binary) bool {
    return switch (bin.operator) {
        .SAL, .SAR, .SHL, .SHR => isMemoryAddress(bin.dst),
        else => false,
    };
}

fn isIllegalCvtsi2sd(cvt: Cvtsi2sd) bool {
    return cvt.src == .Imm or isMemoryAddress(cvt.dst);
}

fn isIllegalCvttsd2si(cvt: Cvttsd2si) bool {
    return isMemoryAddress(cvt.dst);
}

pub fn allocError() noreturn {
    std.log.err("Memory allocation error", .{});
    std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    std.process.exit(1);
}
