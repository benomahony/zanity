const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const Definition = @import("facts.zig").Definition;
const Facts = @import("facts.zig").Facts;
const Finding = @import("facts.zig").Finding;

const directional = [_][]const u8{ "to", "from", "before", "after", "src", "dst" };

const max_tokens = 64;

const Keyed = struct {
    key: []const u8,
    index: u32,

    fn order(_: void, a: Keyed, b: Keyed) bool {
        assert(a.key.len > 0);
        assert(b.key.len > 0);
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

    pub fn initNamingScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!ConceptScratch {
        assert(limits.definitions > 0);
        assert(limits.text_bytes > 0);
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
    assert(enabled.len > 0);
    const definitions = facts.definitions.items();
    std.mem.sort(Definition, definitions, {}, Definition.sourceOrder);
    const before = findings.len;
    if (enabled.enabled("name-drift")) try drift(s, facts.text, definitions, findings);
    if (enabled.enabled("duplicate-name")) try duplicates(s, facts.text, definitions, findings);
    assert(findings.len - before <= definitions.len * 2);
}

fn exempt(name: []const u8) bool {
    assert(name.len > 0);
    const dunder = name.len > 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
    assert(!dunder or name.len > 4);
    return dunder;
}

/// Splits a name into lowercase words, which live in `s.words` until its next reset.
pub fn tokenise(s: *ConceptScratch, name: []const u8) error{LimitExceeded}![]const []const u8 {
    assert(name.len > 0);
    s.tokens.clear();
    var start: usize = 0;
    for (0..name.len + 1) |i| {
        const at_end = i == name.len;
        const separator = !at_end and (name[i] == '_' or name[i] == '-' or std.ascii.isWhitespace(name[i]));
        const boundary = !at_end and i > start and caseBoundary(name, i);
        if (!at_end and !separator and !boundary) continue;
        if (i > start) {
            const word = try s.words.copy(name[start..i]);
            _ = std.ascii.lowerString(@constCast(word), word);
            try s.tokens.add(word);
        }
        start = if (separator) i + 1 else i;
    }
    assert(s.tokens.len <= name.len);
    return s.tokens.items();
}

fn caseBoundary(name: []const u8, i: usize) bool {
    assert(i > 0 and i < name.len);
    const previous = name[i - 1];
    const current = name[i];
    if (std.ascii.isUpper(current) and (std.ascii.isLower(previous) or std.ascii.isDigit(previous))) return true;
    const acronym_end = std.ascii.isUpper(previous) and std.ascii.isUpper(current) and i + 1 < name.len and std.ascii.isLower(name[i + 1]);
    assert(!acronym_end or i + 1 < name.len);
    return acronym_end;
}

/// The language plus the name's words in sorted order, so that reorderings
/// and respellings of the same words share a key.
fn conceptKey(s: *ConceptScratch, language: []const u8, name: []const u8) error{LimitExceeded}![]const u8 {
    const tokens = s.tokens.buffer[0..(try tokenise(s, name)).len];
    std.mem.sort([]const u8, tokens, {}, stringLessThan);
    const start = s.words.used;
    _ = try s.words.copy(language);
    for (tokens) |token| {
        _ = try s.words.copy(" ");
        _ = try s.words.copy(token);
    }
    const key = s.words.buffer[start..s.words.used];
    assert(key.len > language.len);
    assert(tokens.len > 0);
    return key;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    assert(a.len > 0);
    assert(b.len > 0);
    return std.mem.order(u8, a, b) == .lt;
}

fn drift(s: *ConceptScratch, text: *memory.Text, definitions: []const Definition, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    s.words.used = 0;
    s.keyed.clear();
    for (definitions, 0..) |d, i| {
        if (!exempt(d.name)) try s.keyed.add(.{ .key = try conceptKey(s, d.language, d.name), .index = @intCast(i) });
    }
    const keyed = s.keyed.items();
    std.mem.sort(Keyed, keyed, {}, Keyed.order);
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
    assert(start == keyed.len);
    assert(findings.len >= before);
}

fn runEnd(keyed: []const Keyed, start: usize) usize {
    assert(start < keyed.len);
    var end = start + 1;
    while (end < keyed.len and std.mem.eql(u8, keyed[end].key, keyed[start].key)) end += 1;
    assert(end > start);
    return end;
}

fn joined(text: *memory.Text, names: []const []const u8) error{LimitExceeded}![]const u8 {
    assert(names.len > 0);
    const start = text.used;
    for (names, 0..) |name, i| {
        if (i > 0) _ = try text.copy(", ");
        _ = try text.copy(name);
    }
    assert(text.used > start);
    return text.buffer[start..text.used];
}

fn addUnique(list: *memory.Bounded([]const u8), value: []const u8) error{LimitExceeded}!void {
    assert(value.len > 0);
    for (list.items()) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.add(value);
    assert(list.len > 0);
}

fn caseOnlyAcrossKinds(names: []const []const u8, kinds: usize) bool {
    assert(names.len >= 2);
    assert(kinds >= 1);
    if (kinds < 2) return false;
    for (names[1..]) |n| if (!std.ascii.eqlIgnoreCase(n, names[0])) return false;
    return true;
}

/// True when the names differ only in which side of a direction word each
/// part sits, like `copyFromTo` and `copyToFrom`, which are distinct concepts.
fn directionalNames(s: *ConceptScratch, names: []const []const u8) error{LimitExceeded}!bool {
    assert(names.len >= 2);
    s.shapes.clear();
    for (names) |name| {
        const start = s.words.used;
        var sides: usize = 1;
        for (try tokenise(s, name)) |token| {
            if (isDirectional(token)) {
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
    assert(s.shapes.len <= names.len);
    return s.shapes.len == names.len;
}

fn isDirectional(token: []const u8) bool {
    assert(token.len > 0);
    assert(directional.len > 0);
    for (directional) |d| if (std.mem.eql(u8, d, token)) return true;
    return false;
}

fn duplicates(s: *ConceptScratch, text: *memory.Text, definitions: []const Definition, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    s.words.used = 0;
    s.keyed.clear();
    for (definitions, 0..) |d, i| {
        if (!exempt(d.name)) try s.keyed.add(.{ .key = try s.words.format("{s} {s}", .{ d.language, d.name }), .index = @intCast(i) });
    }
    const keyed = s.keyed.items();
    std.mem.sort(Keyed, keyed, {}, Keyed.order);
    var start: usize = 0;
    for (0..keyed.len) |_| {
        if (start == keyed.len) break;
        const end = runEnd(keyed, start);
        defer start = end;
        const sharers = keyed[start..end];
        if (sharers.len < 2) continue;
        for (sharers, 0..) |k, i| {
            const d = definitions[k.index];
            const other = definitions[sharers[if (i == 0) 1 else 0].index];
            try findings.add(.{
                .path = d.path,
                .line = d.line,
                .column = d.column,
                .rule = "duplicate-name",
                .message = try text.format("'{s}' is defined {d} times, for example at {s}:{d}, so readers can't tell which one a use means.", .{ d.name, sharers.len, other.path, other.line + 1 }),
            });
        }
    }
    assert(start == keyed.len);
    assert(findings.len - before <= definitions.len);
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
