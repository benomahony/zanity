//! Splitting a name into its words: on separators such as `_` and `-`, and where the case
//! changes, as between `parse`, `HTTP` and `Request` in `parseHTTPRequest`.
const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const memory = @import("memory.zig");
const Allocator = std.mem.Allocator;
const words = @import("words.zig");
pub const Words = words.Words;
const caseBoundary = words.caseBoundary;

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

/// Words that give a name its direction, unless zanity.toml lists its own.
const default_directional = [_][]const u8{ "to", "from", "before", "after", "src", "dst" };

const max_tokens = 64;

pub const Keyed = struct {
    key: []const u8,
    index: u32,

    pub fn order(_: void, a: Keyed, b: Keyed) bool {
        if (a.key.len == 0) assert.panic("definition {d} has an empty concept key; conceptKey always starts with the language name", .{a.index});
        if (b.key.len == 0) assert.panic("definition {d} has an empty concept key; conceptKey always starts with the language name", .{b.index});
        const by_key = std.mem.order(u8, a.key, b.key);
        return if (by_key == .eq) a.index < b.index else by_key == .lt;
    }
};

pub const ConceptScratch = struct {
    keyed: memory.Bounded(Keyed),
    spellings: memory.Bounded([]const u8),
    kinds: memory.Bounded([]const u8),
    unmarked: memory.Bounded([]const u8),
    shapes: memory.Bounded([]const u8),
    tokens: memory.Bounded([]const u8),
    words: memory.Text,
    directional: []const []const u8 = &default_directional,

    pub fn initNamingScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!ConceptScratch {
        if (limits.definitions == 0) assert.panic("memory.Limits.definitions is 0, so naming checks have no room for any name", .{});
        if (limits.text_bytes == 0) assert.panic("memory.Limits.text_bytes is 0, so naming checks have no room to split names into words", .{});
        return .{
            .keyed = try .initBounded(gpa, limits.definitions, "definitions across all files"),
            .spellings = try .initBounded(gpa, limits.definitions, "spellings of one concept"),
            .kinds = try .initBounded(gpa, limits.definitions, "kinds of one concept"),
            .unmarked = try .initBounded(gpa, limits.definitions, "unmarked spellings of one concept"),
            .shapes = try .initBounded(gpa, limits.definitions, "spellings of one concept"),
            .tokens = try .initBounded(gpa, max_tokens, "words in one name"),
            .words = try .initText(gpa, limits.text_bytes),
        };
    }

    /// Restores configuration that may differ between watched checks.
    pub fn reset(self: *ConceptScratch) void {
        self.directional = &default_directional;
        if (self.directional.len != default_directional.len) assert.panic("reset naming to {d} directional words, expected the {d} defaults", .{ self.directional.len, default_directional.len });
        if (self.words.buffer.len == 0) assert.panic("reset naming lost its word buffer; reset() retains every allocation", .{});
    }
};

/// Names with no words, like Go's blank identifier `_`, which say nothing a reader could confuse.
pub fn exempt(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is exempt from naming checks; the @name capture matched an empty node", .{});
    if (std.mem.indexOfScalar(u8, name, 0) != null) assert.panic("'{s}' holds a NUL byte, which no identifier can; the @name capture matched past the name", .{name});
    const wordless = std.mem.indexOfNone(u8, name, separators) == null;
    if (wordless and std.mem.indexOfNone(u8, name, "_-") != null and std.mem.trim(u8, name, " \t\r\n").len > 0) assert.panic("'{s}' was taken as having no words though it holds more than separators; check separators", .{name});
    return wordless;
}

/// The bytes tokenise() splits words on: underscores, hyphens and whitespace.
pub const separators = "_-" ++ std.ascii.whitespace;
