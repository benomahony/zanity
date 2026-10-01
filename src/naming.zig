const std = @import("std");
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
        if (a.key.len == 0) std.debug.panic("definition {d} has an empty concept key; conceptKey always starts with the language name", .{a.index});
        if (b.key.len == 0) std.debug.panic("definition {d} has an empty concept key; conceptKey always starts with the language name", .{b.index});
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
        if (limits.definitions == 0) std.debug.panic("memory.Limits.definitions is 0, so naming checks have no room for any name", .{});
        if (limits.text_bytes == 0) std.debug.panic("memory.Limits.text_bytes is 0, so naming checks have no room to split names into words", .{});
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
    if (enabled.len == 0) std.debug.panic("cross-file naming checks ran with no rules enabled; runCheck always enables at least one", .{});
    const definitions = facts.definitions.items();
    std.mem.sort(Definition, definitions, {}, Definition.sourceOrder);
    const before = findings.len;
    if (enabled.enabled("name-drift")) try drift(s, facts.text, definitions, findings);
    if (enabled.enabled("duplicate-name")) try duplicates(s, facts.text, definitions, findings);
    if (findings.len - before > definitions.len * 2) std.debug.panic("naming checks reported {d} findings for {d} definitions; each definition can be in at most one drift and one duplicate", .{ findings.len - before, definitions.len });
}

pub fn exempt(name: []const u8) bool {
    if (name.len == 0) std.debug.panic("asked whether an empty name is exempt from naming checks; the @name capture matched an empty node", .{});
    const dunder = name.len > 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
    if (dunder and name.len <= 4) std.debug.panic("'{s}' was taken for a dunder name, but those need at least 5 bytes, like __x__; exempt() must check the length before treating a name as a dunder name", .{name});
    return dunder or std.mem.indexOfNone(u8, name, "_") == null;
}

/// Splits a name into lowercase words, which live in `s.words` until its next reset.
pub fn tokenise(s: *ConceptScratch, name: []const u8) error{LimitExceeded}![]const []const u8 {
    if (name.len == 0) std.debug.panic("asked to split an empty name into words; the @name capture matched an empty node", .{});
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
    if (s.tokens.len > name.len) std.debug.panic("'{s}' ({d} bytes) split into {d} words; a word needs at least one byte", .{ name, name.len, s.tokens.len });
    return s.tokens.items();
}

fn caseBoundary(name: []const u8, i: usize) bool {
    if (i == 0 or i >= name.len) std.debug.panic("checked for a word boundary at byte {d} of '{s}' ({d} bytes); only bytes 1..{d} can start a word", .{ i, name, name.len, name.len -| 1 });
    const previous = name[i - 1];
    const current = name[i];
    if (std.ascii.isUpper(current) and (std.ascii.isLower(previous) or std.ascii.isDigit(previous))) return true;
    const acronym_end = std.ascii.isUpper(previous) and std.ascii.isUpper(current) and i + 1 < name.len and std.ascii.isLower(name[i + 1]);
    if (acronym_end and i + 1 >= name.len) std.debug.panic("'{s}': an acronym ending at byte {d} needs a lowercase byte after it; caseBoundary() must end an acronym before its last capital", .{ name, i });
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
    if (key.len <= language.len) std.debug.panic("the concept key for '{s}' is '{s}', with no words after the language {s}; conceptKey() must write the words after the language prefix", .{ name, key, language });
    if (tokens.len == 0) std.debug.panic("'{s}' split into no words; names need at least one letter or digit", .{name});
    return key;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) std.debug.panic("sorting an empty word against '{s}'; tokenise never returns empty words", .{b});
    if (b.len == 0) std.debug.panic("sorting '{s}' against an empty word; tokenise never returns empty words", .{a});
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
    if (start != keyed.len) std.debug.panic("name-drift stopped at definition {d} of {d}; runEnd must reach the end", .{ start, keyed.len });
    if (findings.len < before) std.debug.panic("name-drift removed findings: {d} before, {d} after; drift() must only add findings", .{ before, findings.len });
}

fn runEnd(keyed: []const Keyed, start: usize) usize {
    if (start >= keyed.len) std.debug.panic("asked for the run of names from {d}, past the {d} names; call runEnd() only with a start below the name count", .{ start, keyed.len });
    var end = start + 1;
    while (end < keyed.len and std.mem.eql(u8, keyed[end].key, keyed[start].key)) end += 1;
    if (end <= start) std.debug.panic("the run of names from {d} ended at {d}; a run holds at least its first name, so runEnd() must start its scan after the first name", .{ start, end });
    return end;
}

fn joined(text: *memory.Text, names: []const []const u8) error{LimitExceeded}![]const u8 {
    if (names.len == 0) std.debug.panic("asked to list no names; a finding about names needs at least one", .{});
    const start = text.used;
    for (names, 0..) |name, i| {
        if (i > 0) _ = try text.copy(", ");
        _ = try text.copy(name);
    }
    if (text.used <= start) std.debug.panic("listing {d} names wrote nothing; names are never empty", .{names.len});
    return text.buffer[start..text.used];
}

fn addUnique(list: *memory.Bounded([]const u8), value: []const u8) error{LimitExceeded}!void {
    if (value.len == 0) std.debug.panic("asked to record an empty name among {d}; names are never empty", .{list.len});
    for (list.items()) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.add(value);
    if (list.len == 0) std.debug.panic("recorded '{s}' but the list is still empty; addUnique() must add the name before returning", .{value});
}

fn caseOnlyAcrossKinds(names: []const []const u8, kinds: usize) bool {
    if (names.len < 2) std.debug.panic("comparing the case of {d} names; drift needs at least 2 spellings", .{names.len});
    if (kinds == 0) std.debug.panic("{d} names ('{s}' first) have no kinds recorded; every definition has a kind", .{ names.len, names[0] });
    if (kinds < 2) return false;
    const first = std.mem.trimStart(u8, names[0], "_");
    for (names[1..]) |n| if (!std.ascii.eqlIgnoreCase(std.mem.trimStart(u8, n, "_"), first)) return false;
    return true;
}

/// True when the names differ only in which side of a direction word each
/// part sits, like `copyFromTo` and `copyToFrom`, which are distinct concepts.
fn directionalNames(s: *ConceptScratch, names: []const []const u8) error{LimitExceeded}!bool {
    if (names.len < 2) std.debug.panic("comparing the direction words of {d} names; drift needs at least 2 spellings", .{names.len});
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
    if (s.shapes.len > names.len) std.debug.panic("{d} names produced {d} shapes; addUnique keeps at most one per name", .{ names.len, s.shapes.len });
    return s.shapes.len == names.len;
}

fn isDirectional(token: []const u8) bool {
    if (token.len == 0) std.debug.panic("asked whether an empty word is a direction word; tokenise never returns empty words", .{});
    if (directional.len == 0) std.debug.panic("the list of direction words is empty, so '{s}' can't be checked", .{token});
    for (directional) |d| if (std.mem.eql(u8, d, token)) return true;
    return false;
}

fn duplicates(s: *ConceptScratch, text: *memory.Text, definitions: []const Definition, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    s.words.used = 0;
    s.keyed.clear();
    for (definitions, 0..) |d, i| {
        if (!exempt(d.name) and !std.mem.eql(u8, d.kind, "method")) try s.keyed.add(.{ .key = try s.words.format("{s} {s}", .{ d.language, d.name }), .index = @intCast(i) });
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
    if (start != keyed.len) std.debug.panic("duplicate-name stopped at definition {d} of {d}; runEnd must reach the end", .{ start, keyed.len });
    if (findings.len - before > definitions.len) std.debug.panic("duplicate-name reported {d} findings for {d} definitions; each definition can be reported once", .{ findings.len - before, definitions.len });
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
