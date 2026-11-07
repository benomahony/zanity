//! Splitting a name into its words: on separators such as `_` and `-`, and where the case
//! changes, as between `parse`, `HTTP` and `Request` in `parseHTTPRequest`.
const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const memory = @import("memory.zig");
const naming = @import("naming.zig");
const ConceptScratch = naming.ConceptScratch;
const Keyed = naming.Keyed;
const exempt = naming.exempt;
const separators = naming.separators;

/// Splits a name into lowercase words, which live in `s.words` until its next reset.
pub fn tokenise(s: *ConceptScratch, name: []const u8) error{LimitExceeded}![]const []const u8 {
    if (name.len == 0) assert.panic("asked to split an empty name into words; the @name capture matched an empty node", .{});
    s.tokens.clear();
    var start: usize = 0;
    for (0..name.len + 1) |i| {
        const at_end = i == name.len;
        const separator = !at_end and std.mem.indexOfScalar(u8, separators, name[i]) != null;
        const boundary = !at_end and i > start and caseBoundary(name, i);
        if (!at_end and !separator and !boundary) continue;
        if (i > start) {
            const word = try s.words.copy(name[start..i]);
            _ = std.ascii.lowerString(@constCast(word), word);
            try s.tokens.add(word);
        }
        start = if (separator) i + 1 else i;
    }
    if (s.tokens.len > name.len) assert.panic("'{s}' ({d} bytes) split into {d} words; a word needs at least one byte", .{ name, name.len, s.tokens.len });
    return s.tokens.items();
}

/// The words of a name, split on anything not a letter or digit and where its case changes, as
/// slices of the name: `parseHTTPRequest` gives parse, HTTP, Request.
pub const Words = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        if (self.at > self.text.len) assert.panic("reading words of '{s}' from byte {d}, past its end; next() must stop at the end", .{ self.text, self.at });
        while (self.at < self.text.len and !std.ascii.isAlphanumeric(self.text[self.at])) self.at += 1;
        if (self.at == self.text.len) return null;
        const start = self.at;
        self.at += 1;
        while (self.at < self.text.len and std.ascii.isAlphanumeric(self.text[self.at]) and !caseBoundary(self.text, self.at)) self.at += 1;
        if (self.at <= start) assert.panic("a word of '{s}' at byte {d} is empty; next() must take at least one byte", .{ self.text, start });
        return self.text[start..self.at];
    }
};

pub fn caseBoundary(name: []const u8, i: usize) bool {
    if (i == 0 or i >= name.len) assert.panic("checked for a word boundary at byte {d} of '{s}' ({d} bytes); only bytes 1..{d} can start a word", .{ i, name, name.len, name.len -| 1 });
    const previous = name[i - 1];
    const current = name[i];
    if (std.ascii.isUpper(current) and (std.ascii.isLower(previous) or std.ascii.isDigit(previous))) return true;
    const acronym_end = std.ascii.isUpper(previous) and std.ascii.isUpper(current) and i + 1 < name.len and std.ascii.isLower(name[i + 1]);
    if (acronym_end and i + 1 >= name.len) assert.panic("'{s}': an acronym ending at byte {d} needs a lowercase byte after it; caseBoundary() must end an acronym before its last capital", .{ name, i });
    return acronym_end;
}

/// The language plus the name's words in sorted order, so that reorderings
/// and respellings of the same words share a key.
pub fn conceptKey(s: *ConceptScratch, language: []const u8, name: []const u8) error{LimitExceeded}![]const u8 {
    const tokens = s.tokens.buffer[0..(try tokenise(s, name)).len];
    std.mem.sort([]const u8, tokens, {}, strings.lessThan);
    const start = s.words.used;
    _ = try s.words.copy(language);
    for (tokens) |token| {
        _ = try s.words.copy(" ");
        _ = try s.words.copy(token);
    }
    const key = s.words.buffer[start..s.words.used];
    if (key.len <= language.len) assert.panic("the concept key for '{s}' is '{s}', with no words after the language {s}; conceptKey() must write the words after the language prefix", .{ name, key, language });
    if (tokens.len == 0) assert.panic("'{s}' split into no words; names need at least one letter or digit", .{name});
    return key;
}

pub fn runEnd(keyed: []const Keyed, start: usize) usize {
    if (start >= keyed.len) assert.panic("asked for the run of names from {d}, past the {d} names; call runEnd() only with a start below the name count", .{ start, keyed.len });
    var end = start + 1;
    while (end < keyed.len and std.mem.eql(u8, keyed[end].key, keyed[start].key)) end += 1;
    if (end <= start) assert.panic("the run of names from {d} ended at {d}; a run holds at least its first name, so runEnd() must start its scan after the first name", .{ start, end });
    return end;
}

pub fn joined(text: *memory.Text, names: []const []const u8) error{LimitExceeded}![]const u8 {
    if (names.len == 0) assert.panic("asked to list no names; a finding about names needs at least one", .{});
    const start = text.used;
    for (names, 0..) |name, i| {
        if (i > 0) _ = try text.copy(", ");
        _ = try text.copy(name);
    }
    if (text.used <= start) assert.panic("listing {d} names wrote nothing; names are never empty", .{names.len});
    return text.buffer[start..text.used];
}

/// Whether two names hold the same words in the same order, ignoring case and separators.
pub fn sameWords(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) assert.panic("comparing the words of '{s}' and '{s}', and one is empty; every definition records a non-empty unmarked name", .{ a, b });
    if (std.mem.indexOfScalar(u8, a, 0) != null or std.mem.indexOfScalar(u8, b, 0) != null) assert.panic("comparing names containing a NUL byte: '{s}' and '{s}'; identifiers cannot contain NUL", .{ a, b });
    var left: Words = .{ .text = a };
    var right: Words = .{ .text = b };
    for (0..a.len + 1) |_| {
        const x = left.next();
        const y = right.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.ascii.eqlIgnoreCase(x.?, y.?)) return false;
    }
    assert.panic("compared more words of '{s}' than it has bytes; Words.next() must move past at least a byte each time", .{a});
}

test "names with no words, like Go's blank identifier, are exempt" {
    try std.testing.expect(exempt("_"));
    try std.testing.expect(exempt("__"));
    try std.testing.expect(!exempt("_x"));
}

test "names split on separators, case changes and acronyms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var s = try ConceptScratch.initNamingScratch(arena_state.allocator(), .{ .definitions = 4, .text_bytes = 256 });
    const cases = .{
        .{ "CustomerAccount", &[_][]const u8{ "customer", "account" } },
        .{ "account_customer", &[_][]const u8{ "account", "customer" } },
        .{ "HTTPServer", &[_][]const u8{ "http", "server" } },
        .{ "parse2Json", &[_][]const u8{ "parse2", "json" } },
        .{ "kebab-case name", &[_][]const u8{ "kebab", "case", "name" } },
    };
    inline for (cases) |c| {
        const tokens = try tokenise(&s, c[0]);
        try std.testing.expectEqual(c[1].len, tokens.len);
        for (c[1], tokens) |want, got| try std.testing.expectEqualStrings(want, got);
    }
}
