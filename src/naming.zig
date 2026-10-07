const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const Allocator = std.mem.Allocator;
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const Definition = @import("facts.zig").Definition;
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;

/// Words that give a name its direction, unless zanity.toml lists its own.
const default_directional = [_][]const u8{ "to", "from", "before", "after", "src", "dst" };

const max_tokens = 64;

const Keyed = struct {
    key: []const u8,
    index: u32,

    fn order(_: void, a: Keyed, b: Keyed) bool {
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
            .shapes = try .initBounded(gpa, limits.definitions, "spellings of one concept"),
            .tokens = try .initBounded(gpa, max_tokens, "words in one name"),
            .words = try .initText(gpa, limits.text_bytes),
        };
    }
};

pub fn crossCheck(s: *ConceptScratch, facts: *Facts, enabled: rules.Set, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    if (enabled.len == 0) assert.panic("cross-file naming checks ran with no rules enabled; runCheck always enables at least one", .{});
    const definitions = facts.definitions.items();
    std.mem.sort(Definition, definitions, {}, Definition.sourceOrder);
    const before = findings.len;
    if (enabled.enabled("name-drift")) try drift(s, facts.text, definitions, findings);
    if (enabled.enabled("duplicate-name")) try duplicates(s, facts.text, definitions, findings);
    if (findings.len - before > definitions.len * 2) assert.panic("naming checks reported {d} findings for {d} definitions; each definition can be in at most one drift and one duplicate", .{ findings.len - before, definitions.len });
}

/// Dunder names, which a language defines rather than the author, and names with no words, like
/// Go's blank identifier `_`, which say nothing a reader could confuse.
fn exempt(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is exempt from naming checks; the @name capture matched an empty node", .{});
    const dunder = name.len > 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
    if (dunder and name.len <= 4) assert.panic("'{s}' was taken for a dunder name, but those need at least 5 bytes, like __x__; exempt() must check the length before treating a name as a dunder name", .{name});
    const wordless = std.mem.indexOfNone(u8, name, separators) == null;
    return dunder or wordless;
}

/// The bytes tokenise() splits words on: underscores, hyphens and whitespace.
const separators = "_-" ++ std.ascii.whitespace;

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
fn conceptKey(s: *ConceptScratch, language: []const u8, name: []const u8) error{LimitExceeded}![]const u8 {
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

fn drift(s: *ConceptScratch, text: *memory.Text, definitions: []const Definition, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const keyed = try keyedBy(s, definitions, .concept);
    var start: usize = 0;
    for (0..keyed.len) |_| {
        if (start == keyed.len) break;
        const end = runEnd(keyed, start);
        defer start = end;
        s.spellings.clear();
        s.kinds.clear();
        for (keyed[start..end]) |k| {
            try addUnique(&s.spellings, definitions[k.index].name);
            try addUnique(&s.kinds, definitions[k.index].kind);
        }
        const names = s.spellings.items();
        if (names.len < 2 or caseOnlyAcrossKinds(names, s.kinds.len)) continue;
        if (try directionalNames(s, names)) continue;
        const first = definitions[keyed[start].index];
        const spellings = try joined(text, names);
        try findings.add(.{
            .path = first.path,
            .line = first.line,
            .column = first.column,
            .rule = "name-drift",
            .message = try text.format("One concept is spelled {d} ways: {s}.", .{ names.len, spellings }),
        });
    }
    if (start != keyed.len) assert.panic("name-drift stopped at definition {d} of {d}; runEnd must reach the end", .{ start, keyed.len });
    if (findings.len < before) assert.panic("name-drift removed findings: {d} before, {d} after; drift() must only add findings", .{ before, findings.len });
}

const KeyBy = enum { concept, name };

/// The definitions that aren't exempt, keyed by their concept or by their exact name in their
/// language, and sorted so the ones that share a key sit together.
fn keyedBy(s: *ConceptScratch, definitions: []const Definition, by: KeyBy) error{LimitExceeded}![]Keyed {
    s.words.used = 0;
    s.keyed.clear();
    for (definitions, 0..) |d, i| {
        if (exempt(d.name)) continue;
        const key = switch (by) {
            .concept => try conceptKey(s, d.language, d.name),
            .name => try s.words.format("{s} {s} {s}", .{ d.language, d.scope, d.name }),
        };
        try s.keyed.add(.{ .key = key, .index = @intCast(i) });
    }
    const keyed = s.keyed.items();
    std.mem.sort(Keyed, keyed, {}, Keyed.order);
    if (keyed.len > definitions.len) assert.panic("keyed {d} names from {d} definitions; keyedBy() adds at most one key per definition", .{ keyed.len, definitions.len });
    if (keyed.len > 1 and Keyed.order({}, keyed[keyed.len - 1], keyed[0])) assert.panic("the {d} keyed names came out unsorted; keyedBy() must sort them by key", .{keyed.len});
    return keyed;
}

fn runEnd(keyed: []const Keyed, start: usize) usize {
    if (start >= keyed.len) assert.panic("asked for the run of names from {d}, past the {d} names; call runEnd() only with a start below the name count", .{ start, keyed.len });
    var end = start + 1;
    while (end < keyed.len and std.mem.eql(u8, keyed[end].key, keyed[start].key)) end += 1;
    if (end <= start) assert.panic("the run of names from {d} ended at {d}; a run holds at least its first name, so runEnd() must start its scan after the first name", .{ start, end });
    return end;
}

fn joined(text: *memory.Text, names: []const []const u8) error{LimitExceeded}![]const u8 {
    if (names.len == 0) assert.panic("asked to list no names; a finding about names needs at least one", .{});
    const start = text.used;
    for (names, 0..) |name, i| {
        if (i > 0) _ = try text.copy(", ");
        _ = try text.copy(name);
    }
    if (text.used <= start) assert.panic("listing {d} names wrote nothing; names are never empty", .{names.len});
    return text.buffer[start..text.used];
}

fn addUnique(list: *memory.Bounded([]const u8), value: []const u8) error{LimitExceeded}!void {
    if (value.len == 0) assert.panic("asked to record an empty name among {d}; names are never empty", .{list.len});
    for (list.items()) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.add(value);
    if (list.len == 0) assert.panic("recorded '{s}' but the list is still empty; addUnique() must add the name before returning", .{value});
}

fn caseOnlyAcrossKinds(names: []const []const u8, kinds: usize) bool {
    if (names.len < 2) assert.panic("comparing the case of {d} names; drift needs at least 2 spellings", .{names.len});
    if (kinds == 0) assert.panic("{d} names ('{s}' first) have no kinds recorded; every definition has a kind", .{ names.len, names[0] });
    if (kinds < 2) return false;
    for (names[1..]) |n| if (!std.ascii.eqlIgnoreCase(n, names[0])) return false;
    return true;
}

/// True when the names differ only in which side of a direction word each
/// part sits, like `copyFromTo` and `copyToFrom`, which are distinct concepts.
fn directionalNames(s: *ConceptScratch, names: []const []const u8) error{LimitExceeded}!bool {
    if (names.len < 2) assert.panic("comparing the direction words of {d} names; drift needs at least 2 spellings", .{names.len});
    s.shapes.clear();
    for (names) |name| {
        const start = s.words.used;
        var sides: usize = 1;
        for (try tokenise(s, name)) |token| {
            if (strings.contains(s.directional, token)) {
                sides += 1;
                _ = try s.words.copy("|");
            } else {
                _ = try s.words.copy(token);
                _ = try s.words.copy(" ");
            }
        }
        if (sides < 2) return false;
        try addUnique(&s.shapes, s.words.buffer[start..s.words.used]);
    }
    if (s.shapes.len > names.len) assert.panic("{d} names produced {d} shapes; addUnique keeps at most one per name", .{ names.len, s.shapes.len });
    return s.shapes.len == names.len;
}

pub fn testNamed(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is a test's; definitions always have names", .{});
    var words: Words = .{ .text = name };
    const first = words.next() orelse return false;
    var last = first;
    while (words.next()) |w| last = w;
    if (last.len == 0) assert.panic("the last word of '{s}' is empty; Words never returns one", .{name});
    return std.ascii.eqlIgnoreCase(first, "test") or std.ascii.eqlIgnoreCase(first, "tests") or std.ascii.eqlIgnoreCase(last, "test") or std.ascii.eqlIgnoreCase(last, "tests");
}

/// Whether a use in another file could mean this definition: it isn't reached through a class or
/// function that holds it, another file can name it, and it isn't a test, which only a runner
/// calls.
fn sharable(d: Definition) bool {
    if (d.name.len == 0) assert.panic("{s}:{d}: a definition has no name; the @name capture matched an empty node", .{ d.path, d.line + 1 });
    if (d.member and d.importable and d.public and d.kind.len == 0) assert.panic("{s}:{d}: '{s}' has no kind; define() records the capture's kind", .{ d.path, d.line + 1, d.name });
    return !d.member and d.importable and !testNamed(d.name);
}

/// Where the other definitions sharing a name are, up to three, and what to do with them.
fn othersFix(text: *memory.Text, definitions: []const Definition, sharers: []const Keyed, self_index: usize) error{LimitExceeded}![]const u8 {
    const start = text.used;
    var listed: usize = 0;
    var rest: usize = 0;
    for (sharers) |k| {
        if (k.index == self_index or !sharable(definitions[k.index])) continue;
        if (listed == 3) {
            rest += 1;
            continue;
        }
        const d = definitions[k.index];
        _ = try text.format("{s}{s}:{d}", .{ if (listed == 0) "The others are at " else ", ", d.path, d.line + 1 });
        listed += 1;
    }
    if (listed == 0) assert.panic("listing the other definitions of '{s}' found none; duplicates() reports a name only when two definitions can share it", .{definitions[self_index].name});
    if (rest > 0) _ = try text.format(" and {d} more", .{rest});
    if (listed + rest + 1 > sharers.len) assert.panic("listed {d} and counted {d} more other definitions of '{s}' among {d}; count each sharer once, leaving out this one", .{ listed, rest, definitions[self_index].name, sharers.len });
    _ = try text.copy(". If they do the same thing, keep one and import it everywhere; if not, name each for what sets it apart.");
    return text.buffer[start..text.used];
}

fn duplicates(s: *ConceptScratch, text: *memory.Text, definitions: []const Definition, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const keyed = try keyedBy(s, definitions, .name);
    var start: usize = 0;
    for (0..keyed.len) |_| {
        if (start == keyed.len) break;
        const end = runEnd(keyed, start);
        defer start = end;
        const sharers = keyed[start..end];
        var top_level: usize = 0;
        var first: ?usize = null;
        var second: ?usize = null;
        for (sharers) |k| if (sharable(definitions[k.index])) {
            top_level += 1;
            if (first == null) first = k.index else if (second == null) second = k.index;
        };
        if (top_level < 2) continue;
        for (sharers) |k| {
            const d = definitions[k.index];
            if (!sharable(d)) continue;
            const other = definitions[if (k.index == first.?) second.? else first.?];
            try findings.add(.{
                .path = d.path,
                .line = d.line,
                .column = d.column,
                .rule = "duplicate-name",
                .message = try text.format("'{s}' is defined {d} times, for example at {s}:{d}, so readers can't tell which one a use means.", .{ d.name, top_level, other.path, other.line + 1 }),
                .fix = try othersFix(text, definitions, sharers, k.index),
            });
        }
    }
    if (start != keyed.len) assert.panic("duplicate-name stopped at definition {d} of {d}; runEnd must reach the end", .{ start, keyed.len });
    if (findings.len - before > definitions.len) assert.panic("duplicate-name reported {d} findings for {d} definitions; each definition can be reported once", .{ findings.len - before, definitions.len });
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
