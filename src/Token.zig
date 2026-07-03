pub const TokenType = enum {
    Identifier,
    Constant,
    Keyword,
    OpenParenthesis,
    CloseParenthesis,
    OpenBrace,
    CloseBrace,
    Semicolon,
};

const Token = struct {
    type: TokenType,
    value: []const u8,
};

const KEYWORDS = [_][]const u8{ "int", "return", "void" };
fn getIdentifierType(token: []const u8) TokenType {
    for (KEYWORDS) |keyword| {
        if (mem.eql(u8, keyword, token)) {
            return .Keyword;
        }
    }
    return .Identifier;
}
