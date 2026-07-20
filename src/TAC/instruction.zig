const Parser = @import("../Parser.zig");

const InstructionTag = enum {
    Binary,
    Return,
    Unary,
    Copy,
    Jump,
    JumpIfZero,
    JumpIfNotZero,
    Label,
};
pub const Instruction = union(InstructionTag) {
    Binary: Binary,
    Return: Return,
    Unary: Unary,
    Copy: Copy,
    Jump: Jump,
    JumpIfZero: JumpIfZero,
    JumpIfNotZero: JumpIfNotZero,
    Label: Label,
};

pub const Return = struct {
    val: Val,
};

pub const Unary = struct {
    pub const Operator = Parser.Unary.Operator;

    operator: Operator,
    src: Val,
    dst: Val,
};

pub const Binary = struct {
    pub const Operator = Parser.Binary.Operator;

    operator: Operator,
    src1: Val,
    src2: Val,
    dst: Val,
};

pub const Copy = struct {
    src: Val,
    dst: Val,
};

pub const Jump = struct { target: []const u8 };

pub const JumpIfZero = struct { condition: Val, target: []const u8 };

pub const JumpIfNotZero = struct { condition: Val, target: []const u8 };

pub const Label = struct { identifier: []const u8 };

const ValTag = enum { Constant, Var };
pub const Val = union(ValTag) {
    Constant: Constant,
    Var: Var,
};

pub const Constant = struct {
    int: []const u8,
};

const Var = []u8;
