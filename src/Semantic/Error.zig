/// For semantic error reporting, given we've successfully parsed the input, when detecting
/// an error, we don't necessarily have to exit immediately. We can report the semantic
/// error, and continue processing the rest of the file. This let's us catch mulitple errors
/// at once, rather than reporting than one-by-one on each run. Hence, we we use an 'enum'
/// instead of an actual 'error' classification
const std = @import("std");
const log = std.log;

pub const SemanticError = enum {
    Break,
    CallOnNonFunction,
    CaseDuplicate,
    CaseOutside,
    Continue,
    IncompatibleFunctions,
    NestedFunction,
    NotAssignable,
    OrphanGoto,
    OrphanLabel,
    Redeclaration,
    TooFewArguments,
    TooManyArguments,
    UndeclaredIdentifier,
    VarUsedAsFunction,
};

pub const Reporter = struct {
    textLines: [][]const u8,
    errorFlag: bool = false,

    pub fn init(textLines: [][]const u8) Reporter {
        return .{ .textLines = textLines };
    }

    pub fn report(self: *Reporter, err: SemanticError, lineIndex: usize, name: ?[]const u8) void {
        switch (err) {
            .Break => log.err("'break' statement outside of loop or switch statement", .{}),
            .CallOnNonFunction => log.err("Called object is not a function or function pointer", .{}),
            .CaseOutside => log.err("'case' or 'default' label outside of switch statement", .{}),
            .CaseDuplicate => log.err("Duplicate 'case' or 'default'", .{}),
            .Continue => log.err("'continue' statement outside of loop statement", .{}),
            .IncompatibleFunctions => log.err("Incompatible function declarations", .{}),
            .NotAssignable => log.err("Expression is not an assignable lvalue", .{}),
            .NestedFunction => log.err("Function definitions may only exist at the top level", .{}),
            .OrphanGoto => {},
            .OrphanLabel => log.err("Label '{s}' outside of function scope", .{name.?}),
            .Redeclaration => log.err("Redeclaration of '{s}'", .{name.?}),
            .TooFewArguments => log.err("Too few arguments in function call", .{}),
            .TooManyArguments => log.err("Too many arguments in function call", .{}),
            .UndeclaredIdentifier => log.err("Use of undeclared identifier '{s}'", .{name.?}),
            .VarUsedAsFunction => log.err("Function '{s}' cannot be used as a variable", .{name.?}),
        }
        log.err(" {d} |{s}\n", .{ lineIndex + 1, self.textLines[lineIndex] });

        self.errorFlag = true;
    }
};
