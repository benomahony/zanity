//! What two functions of the same structure differ in: their bodies tokenised the same way and
//! compared token by token, which lines up because the structure is the same. The tokens that
//! differ are the names and values one would pass in to keep only one of them.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");

/// Differing pairs a fix names; the rest are counted.
const max_shown = 4;
/// Distinct differing pairs past which the two are only alike in shape, not copies of each other.
const max_pairs = 64;

/// A body to compare: its bytes and the line comment marker of its language, so comments, which
/// structure leaves out, are left out here too.
pub const Body = struct { bytes: []const u8, line_comment: []const u8 };

/// The fix for a function that has `other_name`'s structure: what differs between their bodies
/// and what to do about it, empty when the bodies don't line up token by token, or null when they
/// differ in so many names and values that they only share a shape and aren't copies.
pub fn differenceFix(text: *memory.Text, mine: Body, theirs: Body, other_name: []const u8) error{LimitExceeded}!?[]const u8 {
    if (other_name.len == 0) assert.panic("comparing a body with an unnamed twin; structural-twins names every function it reports", .{});
    var pairs: [max_pairs][2][]const u8 = undefined;
    var distinct: usize = 0;
    var a: Tokens = .{ .bytes = mine.bytes, .line_comment = mine.line_comment };
    var b: Tokens = .{ .bytes = theirs.bytes, .line_comment = theirs.line_comment };
    for (0..mine.bytes.len + 1) |_| {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) break;
        if (x == null or y == null) return "";
        if (std.mem.eql(u8, x.?, y.?)) continue;
        if (seen(pairs[0..distinct], x.?, y.?)) continue;
        if (distinct == max_pairs) return null;
        pairs[distinct] = .{ x.?, y.? };
        distinct += 1;
    }
    if (distinct == 0) return try text.format("Its body is identical to that of '{s}'; delete one and call the other.", .{other_name});
    const start = text.used;
    _ = try text.format("It differs from '{s}' only in ", .{other_name});
    for (pairs[0..@min(distinct, max_shown)], 0..) |pair, i| {
        const separator = if (i == 0) "" else if (i + 1 == @min(distinct, max_shown) and distinct <= max_shown) " and " else ", ";
        const shared = Shared.of(pair[0], pair[1]);
        _ = try text.format("{s}{f} where it has {f}", .{ separator, shared.code(pair[0]), shared.code(pair[1]) });
    }
    if (distinct > max_shown) _ = try text.format(" and {d} more", .{distinct - max_shown});
    _ = try text.copy("; keep one, and pass what differs in as parameters.");
    const fix = text.buffer[start..text.used];
    if (distinct > max_pairs) assert.panic("kept {d} differing pairs in room for {d}; differenceFix() must stop at max_pairs", .{ distinct, max_pairs });
    return fix;
}

/// Tokens longer than this show only the part that differs, with `context` bytes around it.
const max_token = 40;
const context = 8;

/// How many bytes two differing tokens share at their start and at their end.
const Shared = struct {
    prefix: usize,
    suffix: usize,

    fn of(a: []const u8, b: []const u8) Shared {
        if (std.mem.eql(u8, a, b)) assert.panic("finding what '{s}' shares with itself; differenceFix() pairs only tokens that differ", .{a});
        const shortest = @min(a.len, b.len);
        var prefix: usize = 0;
        while (prefix < shortest and a[prefix] == b[prefix]) prefix += 1;
        var suffix: usize = 0;
        while (suffix < shortest - prefix and a[a.len - 1 - suffix] == b[b.len - 1 - suffix]) suffix += 1;
        if (prefix + suffix > shortest) assert.panic("two tokens of {d} and {d} bytes share {d} at the start and {d} at the end, more than the shorter has; the suffix must stop where the prefix ends", .{ a.len, b.len, prefix, suffix });
        return .{ .prefix = prefix, .suffix = suffix };
    }

    /// `token` as inline code: whole when short, otherwise the part that differs with a little
    /// around it.
    fn code(self: Shared, token: []const u8) Code {
        if (token.len == 0) assert.panic("showing an empty token; Tokens.next() never returns one", .{});
        if (token.len <= max_token) return .{ .token = token };
        const from = self.prefix -| context;
        const to = @min(token.len - (self.suffix -| context), from + max_token);
        if (to <= from) assert.panic("cut a {d}-byte token to bytes {d}..{d}; two differing tokens can't share all of the longer one", .{ token.len, from, to });
        return .{ .token = token[from..to], .cut_start = from > 0, .cut_end = to < token.len };
    }
};

/// Part of a token as inline code, with `...` where it was cut, fenced with two backticks when it
/// holds one.
const Code = struct {
    token: []const u8,
    cut_start: bool = false,
    cut_end: bool = false,

    pub fn format(self: Code, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.token.len == 0 and !self.cut_start and !self.cut_end) assert.panic("formatting an empty token; Tokens.next() never returns one", .{});
        if (self.token.len > max_token and (self.cut_start or self.cut_end)) assert.panic("a cut token is still {d} bytes, past the {d} allowed; Shared.code() must cut to max_token", .{ self.token.len, max_token });
        const fence = if (std.mem.indexOfScalar(u8, self.token, '`') != null) "`` " else "`";
        try w.print("{s}{s}{s}{s}{s}", .{ fence, if (self.cut_start) "..." else "", self.token, if (self.cut_end) "..." else "", if (fence.len > 1) " ``" else "`" });
    }
};

fn seen(pairs: []const [2][]const u8, x: []const u8, y: []const u8) bool {
    if (pairs.len > max_pairs) assert.panic("searching {d} pairs in room for {d}; differenceFix() stops at max_pairs", .{ pairs.len, max_pairs });
    if (std.mem.eql(u8, x, y)) assert.panic("looking up the pair '{s}'/'{s}', which don't differ; differenceFix() skips equal tokens first", .{ x, y });
    for (pairs) |p| if (std.mem.eql(u8, p[0], x) and std.mem.eql(u8, p[1], y)) return true;
    return false;
}

/// The tokens of a body: names and numbers, quoted strings, and single other characters, with
/// whitespace and line comments left out.
const Tokens = struct {
    bytes: []const u8,
    line_comment: []const u8,
    at: usize = 0,

    fn next(self: *Tokens) ?[]const u8 {
        const b = self.bytes;
        if (self.at > b.len) assert.panic("reading tokens from byte {d} of {d}; next() never moves past the end", .{ self.at, b.len });
        self.skipSpaceAndComments();
        if (self.at == b.len) return null;
        const start = self.at;
        self.at = tokenEnd(b, start);
        if (self.at <= start) assert.panic("a token at byte {d} of {d} took no bytes; tokenEnd() must move past every token", .{ start, b.len });
        return b[start..self.at];
    }

    fn skipSpaceAndComments(self: *Tokens) void {
        const b = self.bytes;
        const comment = self.line_comment;
        if (std.mem.indexOfAny(u8, comment, " \t\r\n") != null) assert.panic("the line comment marker '{s}' holds whitespace, which skipping whitespace first would never match; fix line_comment in languages/tables.zon", .{comment});
        for (0..b.len + 1) |_| {
            while (self.at < b.len and std.ascii.isWhitespace(b[self.at])) self.at += 1;
            if (self.at == b.len or comment.len == 0 or !std.mem.startsWith(u8, b[self.at..], comment)) return;
            self.at = std.mem.indexOfScalarPos(u8, b, self.at, '\n') orelse b.len;
        }
        if (self.at < b.len) assert.panic("skipped {d} comments in a {d}-byte body without reaching code or its end; each pass skips at least a byte", .{ b.len + 1, b.len });
    }
};

/// Where the token starting at `start` ends: a run of name characters, a quoted string up to its
/// closing quote or the end of the line, or one other character.
fn tokenEnd(b: []const u8, start: usize) usize {
    if (start >= b.len) assert.panic("asked for a token at byte {d} of a {d}-byte body; next() stops at the end", .{ start, b.len });
    const c = b[start];
    var at = start + 1;
    if (std.ascii.isAlphanumeric(c) or c == '_') {
        while (at < b.len and (std.ascii.isAlphanumeric(b[at]) or b[at] == '_')) at += 1;
    } else if (c == '"' or c == '\'' or c == '`') {
        while (at < b.len and b[at] != c and b[at] != '\n') at += if (b[at] == '\\' and at + 1 < b.len) 2 else 1;
        at = @min(at + 1, b.len);
    }
    if (at > b.len) assert.panic("a token from byte {d} ran to {d}, past the {d}-byte body; stop at the end", .{ start, at, b.len });
    return at;
}

test "twins that differ in a value name the pair to pass in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var text = try memory.Text.initText(arena_state.allocator(), 4096);
    const a: Body = .{ .bytes = "    return fetch(\"issues\", limit=10)  # first\n", .line_comment = "#" };
    const b: Body = .{ .bytes = "    return fetch(\"prs\", limit=20)\n", .line_comment = "#" };
    try std.testing.expectEqualStrings("It differs from 'prs' only in `\"issues\"` where it has `\"prs\"` and `10` where it has `20`; keep one, and pass what differs in as parameters.", (try differenceFix(&text, a, b, "prs")).?);
    try std.testing.expectEqualStrings("Its body is identical to that of 'prs'; delete one and call the other.", (try differenceFix(&text, a, a, "prs")).?);
}
