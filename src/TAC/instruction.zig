const Parser = @import("../Parser.zig");

pub const Instruction = union(enum) {
    Binary: Binary,
    Copy: Copy,
    DoubleToInt: DoubleToInt,
    DoubleToUInt: DoubleToUInt,
    FunCall: FunCall,
    IntToDouble: IntToDouble,
    Jump: Jump,
    JumpIfNotZero: JumpIfNotZero,
    JumpIfZero: JumpIfZero,
    Label: Label,
    Return: Return,
    SignExtend: SignExtend,
    Truncate: Truncate,
    UIntToDouble: UIntToDouble,
    Unary: Unary,
    ZeroExtend: ZeroExtend,
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

pub const DoubleToInt = struct { src: Val, dst: Val };

pub const DoubleToUInt = struct { src: Val, dst: Val };

pub const FunCall = struct { name: []const u8, args: []Val, dst: Val };

pub const IntToDouble = struct { src: Val, dst: Val };

pub const UIntToDouble = struct { src: Val, dst: Val };

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

pub const ZeroExtend = struct { src: Val, dst: Val };

pub const Val = union(enum) { Constant: Constant, Var: Var };

pub const Var = []const u8;
