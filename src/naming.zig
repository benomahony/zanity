const std = @import("std");
const name_words = @import("name_words.zig");
pub const Words = name_words.Words;
const tokenise = name_words.tokenise;
const runEnd = name_words.runEnd;
const joined = name_words.joined;
const sameWords = name_words.sameWords;
const conceptKey = name_words.conceptKey;
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const Allocator = std.mem.Allocator;
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Definition = facts_module.Definition;
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Tables = @import("language.zig").Tables;
const check = @import("check.zig");
/// How many other holders a duplicate-name fix names before counting the rest.
const max_others_listed = 3;
const Context = check.Context;
const File = check.File;

/// Words that give a name its direction, unless zanity.toml lists its own.
const default_directional = [_][]const u8{ "to", "from", "before", "after", "src", "dst" };

const max_tokens = 64;

pub const Keyed = struct {
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

pub fn crossCheck(s: *ConceptScratch, facts: *Facts, enabled: rules.Set, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    if (enabled.len == 0) assert.panic("cross-file naming checks ran with no rules enabled; runCheck always enables at least one", .{});
    const definitions = facts.definitions.items();
    std.mem.sort(Definition, definitions, {}, Definition.sourceOrder);
    const before = findings.len;
    if (enabled.enabled("name-drift")) try drift(s, facts.text, definitions, findings);
    if (enabled.enabled("duplicate-name")) try duplicates(s, facts.text, definitions, findings);
    if (findings.len - before > definitions.len * 2) assert.panic("naming checks reported {d} findings for {d} definitions; each definition can be in at most one drift and one duplicate", .{ findings.len - before, definitions.len });
}

/// Names with no words, like Go's blank identifier `_`, which say nothing a reader could confuse.
pub fn exempt(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is exempt from naming checks; the @name capture matched an empty node", .{});
    if (std.mem.indexOfScalar(u8, name, 0) != null) assert.panic("'{s}' holds a NUL byte, which no identifier can; the @name capture matched past the name", .{name});
    const wordless = std.mem.indexOfNone(u8, name, separators) == null;
    if (wordless and std.mem.indexOfNone(u8, name, "_-") != null and std.mem.trim(u8, name, " \t\r\n").len > 0) assert.panic("'{s}' was taken as having no words though it holds more than separators; check separators", .{name});
    return wordless;
}

pub fn protocolName(tables: *const Tables, name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is a protocol name; the @name capture matched an empty node", .{});
    if (tables.ecosystem.len == 0) assert.panic("checking protocol name '{s}' against an unnamed ecosystem; every language table names its ecosystem", .{name});
    const affix = tables.protocol_affix;
    const wrapped = affix.len > 0 and name.len > affix.len * 2 and std.mem.startsWith(u8, name, affix) and std.mem.endsWith(u8, name, affix);
    return wrapped or strings.contains(tables.protocol_names, name);
}

pub fn unmarkedName(text: *memory.Text, path: []const u8, tables: *const Tables, name: []const u8) error{LimitExceeded}![]const u8 {
    if (name.len == 0) assert.panic("{s}: asked for the unmarked spelling of an empty name; the @name capture matched an empty node", .{path});
    const bare = std.mem.trimStart(u8, name, tables.private_prefixes);
    const unmarked = try text.copy(if (bare.len == 0) name else bare);
    if (tables.exported_by_case) @constCast(unmarked)[0] = std.ascii.toUpper(unmarked[0]);
    if (unmarked.len > name.len) assert.panic("{s}: the unmarked spelling '{s}' is longer than '{s}'; unmarkedName() may only drop privacy marks", .{ path, unmarked, name });
    return unmarked;
}

pub fn closeDefinition(self: *File, ctx: Context) !void {
    if (ctx.family != .definition) assert.panic("{s}: closing {f} as a definition, but it is a {t}; close() must dispatch each construct by its family", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (ctx.kind.len == 0) assert.panic("{s}: the definition {f} has no kind; capture it as @definition.function, @definition.class and so on", .{ self.work.facts.path, ctx.node.where() });
    const name_node = ctx.name orelse return;
    const name = name_node.text(self.source);
    if (self.checker.enabled.enabled("dead-symbol")) try self.s.names.tally(facts_module.nameHash(name), -1);
    if (std.mem.eql(u8, ctx.kind, "constant") and !std.ascii.isUpper(name[0])) return;
    if (protocolName(self.tables, name)) return;
    const at = ts.ts_node_start_point(name_node);
    const public = self.index.marks(ctx.node, self.v.visibility_public) or (self.tables.exported_by_case and std.ascii.isUpper(name[0]));
    const method = std.mem.eql(u8, ctx.kind, "function") and self.innermost(.function) != null and self.definedInClass();
    const member = method or std.mem.eql(u8, ctx.kind, "method") or heldByFunctionOrClass(self, ctx.node);
    const prefixes = self.tables.private_prefixes;
    // A module exports names explicitly; elsewhere a name is importable unless marked private.
    const importable = if (prefixes.len > 0 and !self.module) std.mem.indexOfScalar(u8, prefixes, name[0]) == null else public;
    try self.work.facts.define(name, if (method) "method" else ctx.kind, .{ .at = .{ at.row, at.column }, .public = public, .member = member, .importable = importable, .unmarked = try unmarkedName(self.work.facts.text, self.work.facts.path, self.tables, name) });
}

/// Whether any statement of the file is an `import` or `export`: whether `id`, the
/// @module.syntax capture, is among the file's captures.
pub fn usesModuleSyntax(id: ?captures.Id, found: []const captures.Triple, source: []const u8) bool {
    const module = id orelse return false;
    for (found) |t| {
        if (t.id != module) continue;
        if (ts.ts_node_end_byte(t.node) > source.len) assert.panic("an import or export ends at byte {d} of a {d}-byte file; pass the source its captures came from", .{ ts.ts_node_end_byte(t.node), source.len });
        return true;
    }
    if (found.len > 0 and source.len == 0) assert.panic("{d} captures in an empty file; pass the source its captures came from", .{found.len});
    return false;
}

fn heldByFunctionOrClass(self: *File, node: ts.Node) bool {
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    if (end <= start) assert.panic("{s}: the definition {f} covers no text; put @definition.<kind> on the whole declaration", .{ self.work.facts.path, node.where() });
    for (self.s.contexts.items()) |held| {
        if (held.family != .function and held.family != .class) continue;
        const from = ts.ts_node_start_byte(held.node);
        const to = ts.ts_node_end_byte(held.node);
        if (from == start and to == end) continue;
        if (from <= start and end <= to) return true;
    }
    if (self.s.contexts.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; leave() must pop what enter() opened", .{ self.work.facts.path, self.s.contexts.len, self.s.contexts.capacity() });
    return false;
}

/// The bytes tokenise() splits words on: underscores, hyphens and whitespace.
pub const separators = "_-" ++ std.ascii.whitespace;

fn drift(s: *ConceptScratch, text: *memory.Text, definitions: []const Definition, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const keyed = try keyedBy(s, definitions, .concept);
    var start: usize = 0;
    for (0..keyed.len) |_| {
        if (start == keyed.len) break;
        const end = runEnd(keyed, start);
        defer start = end;
        const group = keyed[start..end];
        s.spellings.clear();
        s.kinds.clear();
        s.unmarked.clear();
        for (group) |k| {
            const d = definitions[k.index];
            try addUnique(&s.spellings, d.name);
            try addUnique(&s.kinds, d.kind);
            try addUnique(&s.unmarked, d.unmarked);
        }
        const names = s.spellings.items();
        if (names.len < 2 or conventionOnly(definitions, group, s.unmarked.items(), s.kinds.len)) continue;
        if (try directionalNames(s, names)) continue;
        const first = definitions[keyed[start].index];
        const spellings = try joined(text, names);
        const common = mostUsed(definitions, group, names);
        try findings.add(.{
            .path = first.path,
            .line = first.line,
            .column = first.column,
            .rule = "name-drift",
            .message = try text.format("One concept is spelled {d} ways: {s}.", .{ names.len, spellings }),
            .fix = try text.format("Use '{s}', which {d} of the {d} definitions already use, and rename the others to it.", .{ common.name, common.uses, end - start }),
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
        if (by == .name and std.mem.eql(u8, d.kind, "method")) continue;
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

fn addUnique(list: *memory.Bounded([]const u8), value: []const u8) error{LimitExceeded}!void {
    if (value.len == 0) assert.panic("asked to record an empty name among {d}; names are never empty", .{list.len});
    for (list.items()) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.add(value);
    if (list.len == 0) assert.panic("recorded '{s}' but the list is still empty; addUnique() must add the name before returning", .{value});
}

fn conventionOnly(definitions: []const Definition, run: []const Keyed, unmarked: []const []const u8, kinds: usize) bool {
    if (unmarked.len == 0 or unmarked.len > run.len) assert.panic("a run of {d} names has {d} unmarked spellings; closeDefinition() records one for every definition", .{ run.len, unmarked.len });
    if (kinds == 0) assert.panic("{d} unmarked spellings ('{s}' first) have no kinds recorded; every definition has a kind", .{ unmarked.len, unmarked[0] });
    if (unmarked.len == 1) return true;
    if (kinds < 2) return false;
    for (unmarked[1..]) |u| if (!sameWords(u, unmarked[0])) return false;
    for (run, 0..) |a, i| {
        const first = definitions[a.index];
        for (run[i + 1 ..]) |b| {
            const second = definitions[b.index];
            if (std.mem.eql(u8, first.kind, second.kind) and !std.mem.eql(u8, first.unmarked, second.unmarked)) return false;
        }
    }
    return true;
}

/// The spelling most of the definitions of one concept use, and how many use it.
fn mostUsed(definitions: []const Definition, run: []const Keyed, names: []const []const u8) struct { name: []const u8, uses: usize } {
    if (names.len == 0 or run.len == 0) assert.panic("choosing a spelling from {d} names and {d} definitions; drift() passes at least two of each", .{ names.len, run.len });
    var best = names[0];
    var best_uses: usize = 0;
    for (names) |candidate| {
        var uses: usize = 0;
        for (run) |k| uses += @intFromBool(std.mem.eql(u8, definitions[k.index].name, candidate));
        if (uses > best_uses) {
            best = candidate;
            best_uses = uses;
        }
    }
    if (best_uses == 0) assert.panic("no definition uses any of the {d} spellings, starting '{s}'; they come from these definitions", .{ names.len, names[0] });
    return .{ .name = best, .uses = best_uses };
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
        if (listed == max_others_listed) {
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
