const std = @import("std");
const re = @import("regex");

const Regex = @This();

inner: *re.regex_t,

pub fn init(pattern: [:0]const u8) !Regex {
    const inner = re.alloc_regex_t().?;
    if (0 != re.regcomp(inner, pattern, re.REG_EXTENDED)) {
        return error.compile;
    }

    return .{
        .inner = inner,
    };
}

pub fn deinit(self: Regex) void {
    re.free_regex_t(self.inner);
}

pub fn exec(self: Regex, input: [:0]const u8, matchGroup: usize) ?[]const u8 {
    const match_size = 2;
    var pmatch: [match_size]re.regmatch_t = undefined;

    if (0 == re.regexec(self.inner, input, match_size, &pmatch, 0)) {
        const out = input[@as(usize, @intCast(pmatch[matchGroup].rm_so))..@as(usize, @intCast(pmatch[matchGroup].rm_eo))];
        return out;
    }

    return null;
}
