/// For semantic error reporting, given we've successfully parsed the input, when detecting
/// an error, we don't necessarily have to exit immediately. We can report the semantic
/// error, and continue processing the rest of the file. This let's us catch mulitple errors
/// at once, rather than reporting than one-by-one on each run. Hence, we we use an 'enum'
/// instead of an actual 'error' classification
const std = @import("std");
const log = std.log;

pub const SemanticError = enum {
    BlockScopeStaticFunDecl,
    Break,
    CallOnNonFunction,
    CaseDuplicate,
    CaseOutside,
    ConflictingFunctions,
    ConflictingLinkage,
    Continue,
    DefaultArgument,
    ForLoopFunctionDecl,
    ForLoopStorageClassDecl,
    InvalidStaticDeclaration,
    LocalExternDefined,
    NestedFunction,
    NonConstInitializer,
    NotAssignable,
    OrphanGoto,
    OrphanLabel,
    Redeclaration,
    InvalidStorageClass,
    TooFewArguments,
    TooManyArguments,
    UndeclaredIdentifier,
    UnresolvedSymbol,
    VarUsedAsFunction,
    VariableRedefinition,
};

pub const Reporter = struct {
    textLines: [][]const u8,
    errorFlag: bool = false,

    pub fn init(textLines: [][]const u8) Reporter {
        return .{ .textLines = textLines };
    }

    pub fn report(self: *Reporter, err: SemanticError, lineIndex: usize, name: ?[]const u8) void {
        switch (err) {
            .BlockScopeStaticFunDecl => log.err("Function declared in block scope cannot have a 'static' storage class", .{}),
            .Break => log.err("'break' statement outside of loop or switch statement", .{}),
            .CallOnNonFunction => log.err("Called object is not a function or function pointer", .{}),
            .CaseDuplicate => log.err("Duplicate 'case' or 'default'", .{}),
            .CaseOutside => log.err("'case' or 'default' label outside of switch statement", .{}),
            .ConflictingLinkage => log.err("Conflicting variable linkage", .{}),
            .Continue => log.err("'continue' statement outside of loop statement", .{}),
            .ConflictingFunctions => log.err("Conflicting types for '{s}'", .{name.?}),
            .DefaultArgument => log.err("C does not support default arguments", .{}),
            .ForLoopFunctionDecl => log.err("Expected variable declarator or expression", .{}),
            .ForLoopStorageClassDecl => log.err("Variables declared in for loop headers cannot have a storage class", .{}),
            .LocalExternDefined => log.err("Declaration of block scope identifier with linkage cannot have an initializer", .{}),
            .InvalidStaticDeclaration => log.err("Static declaration  of '{s}' follows  non-static declaration", .{name.?}),
            .NestedFunction => log.err("Function definitions may only exist at the top level", .{}),
            .NotAssignable => log.err("Expression is not an assignable lvalue", .{}),
            .NonConstInitializer => log.err("Initializer is not a compile-time constant", .{}),
            .OrphanGoto => log.err("goto statement outside of function scope", .{}),
            .OrphanLabel => log.err("Label '{s}' outside of function scope", .{name.?}),
            .Redeclaration => log.err("Redeclaration of '{s}'", .{name.?}),
            .TooFewArguments => log.err("Too few arguments in function call", .{}),
            .TooManyArguments => log.err("Too many arguments in function call", .{}),
            .InvalidStorageClass => log.err("Type name does not allow storage class to be specified", .{}),
            .UndeclaredIdentifier => log.err("Use of undeclared identifier '{s}'", .{name.?}),
            .UnresolvedSymbol => log.err("Could not resolve symbol '{s}'", .{name.?}),
            .VarUsedAsFunction => log.err("Function '{s}' cannot be used as a variable", .{name.?}),
            .VariableRedefinition => log.err("Redfinition of '{s}'", .{name.?}),
        }
        log.err(" {d} |{s}\n", .{ lineIndex + 1, self.textLines[lineIndex] });

        self.errorFlag = true;
    }
};
