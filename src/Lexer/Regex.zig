const std = @import("std");
const re = @import("regex");

const PatternMatch = struct {
    start: usize,
    end: usize,
};

const Self = @This();

inner: *re.regex_t,

pub fn init(pattern: [:0]const u8) !Self {
    const inner = re.alloc_regex_t().?;
    if (0 != re.regcomp(inner, pattern, re.REG_EXTENDED)) {
        return error.compile;
    }

    return .{
        .inner = inner,
    };
}

pub fn deinit(self: Self) void {
    re.free_regex_t(self.inner);
}

pub fn exec(self: Self, input: [:0]const u8) ?[]const u8 {
    const match_size = 1;
    var pmatch: [match_size]re.regmatch_t = undefined;

    if (0 == re.regexec(self.inner, input, match_size, &pmatch, 0)) {
        return input[@as(usize, @intCast(pmatch[0].rm_so))..@as(usize, @intCast(pmatch[0].rm_eo))];
    }

    return null;
}
