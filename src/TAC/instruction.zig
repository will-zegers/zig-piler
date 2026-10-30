const Parser = @import("../Parser.zig");

const InstructionTag = enum {
    Binary,
    Copy,
    FunCall,
    Jump,
    JumpIfNotZero,
    JumpIfZero,
    Label,
    Return,
    SignExtend,
    Truncate,
    Unary,
};
pub const Instruction = union(InstructionTag) {
    Binary: Binary,
    Copy: Copy,
    FunCall: FunCall,
    Jump: Jump,
    JumpIfNotZero: JumpIfNotZero,
    JumpIfZero: JumpIfZero,
    Label: Label,
    Return: Return,
    SignExtend: SignExtend,
    Truncate: Truncate,
    Unary: Unary,
};

pub const Binary = struct {
    pub const Operator = Parser.Binary.Operator;

    operator: Operator,
    src1: Val,
    src2: Val,
    dst: Val,
};

pub const Constant = Parser.Constant;

pub const Copy = struct { src: Val, dst: Val };

pub const FunCall = struct { name: []const u8, args: []Val, dst: Val };

pub const Jump = struct { target: []const u8 };

pub const JumpIfNotZero = struct { condition: Val, target: []const u8 };

pub const JumpIfZero = struct { condition: Val, target: []const u8 };

pub const Label = struct { identifier: []const u8 };

pub const Return = struct { val: Val };

pub const SignExtend = struct { src: Val, dst: Val };

pub const Truncate = struct { src: Val, dst: Val };

pub const Unary = struct {
    pub const Operator = Parser.Unary.Operator;

    operator: Operator,
    src: Val,
    dst: Val,
};

const ValTag = enum { Constant, Var };
pub const Val = union(ValTag) { Constant: Constant, Var: Var };

const Var = []const u8;
