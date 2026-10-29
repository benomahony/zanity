//! Cross-file checks of what the code is made of: functions with the same structure, definitions
//! nothing refers to, and abstractions with only one implementation.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const language = @import("language.zig");
const check = @import("check.zig");
const naming = @import("naming.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Shape = facts_module.Shape;
const Definition = facts_module.Definition;
const nameHash = facts_module.nameHash;
const Reference = facts_module.Reference;
const twins_module = @import("twins.zig");
const Io = std.Io;

/// What structural-twins re-reads two files with, to say how twins differ: the run's Io and two
/// buffers of the largest file size. Null leaves twins with only the rule's advice.
pub const Sources = struct { io: Io, mine: []u8, theirs: []u8 };

/// What the structure checks work in beyond the facts: files to re-read for twins, and memory
/// reserved for tracing which names are reachable.
pub const Scratch = struct { sources: ?Sources = null, live: ?*LiveScratch = null };

/// Memory dead-symbol traces reachability in, reserved up front for the most definitions a run holds.
pub const LiveScratch = struct {
    candidates: []u64,
    others: []u64,
    alive: []bool,

    pub fn initLiveScratch(gpa: std.mem.Allocator, limits: memory.Limits) std.mem.Allocator.Error!LiveScratch {
        if (limits.definitions == 0) assert.panic("memory.Limits.definitions is 0, so dead-symbol has no room for any name", .{});
        const live: LiveScratch = .{
            .candidates = try memory.reserveUninitialized(gpa, u64, limits.definitions),
            .others = try memory.reserveUninitialized(gpa, u64, limits.definitions),
            .alive = try memory.reserveUninitialized(gpa, bool, limits.definitions),
        };
        if (live.alive.len != live.candidates.len) assert.panic("reserved {d} flags for {d} names", .{ live.alive.len, live.candidates.len });
        return live;
    }
};

pub fn checkStructure(facts: *Facts, enabled: rules.Set, findings: *memory.Bounded(Finding), scratch: Scratch) error{LimitExceeded}!void {
    if (enabled.len == 0) assert.panic("cross-file structure checks ran with no rules enabled; runCheck always enables at least one", .{});
    const before = findings.len;
    if (enabled.enabled("structural-twins")) try twins(facts, findings, scratch.sources);
    if (enabled.enabled("dead-symbol")) try deadSymbols(facts, findings, scratch.live);
    if (enabled.enabled("single-impl-abstraction")) try singleImplementations(facts, findings);
    if (findings.len < before) assert.panic("cross-file structure checks dropped findings from {d} to {d}; they may only add", .{ before, findings.len });
}

fn byShape(_: void, a: Shape, b: Shape) bool {
    if (a.size == 0 or b.size == 0) assert.panic("sorting a function shape of no nodes; recordShape() keeps only shapes of min_twin_nodes or more", .{});
    if (a.function == b.function and a.hash != b.hash) assert.panic("function {d} has two shapes; recordShape() records one per function", .{a.function});
    if (a.is_test != b.is_test) return !a.is_test;
    if (a.hash != b.hash) return a.hash < b.hash;
    return a.function < b.function;
}

/// Where the run of shapes alike to `shapes[start]` ends: the same hash, size and testness.
fn groupEnd(shapes: []const Shape, start: usize) usize {
    if (start >= shapes.len) assert.panic("grouping shapes from {d} of {d}; twins() and clusterUnits() must stop their loops at the last shape before calling groupEnd()", .{ start, shapes.len });
    const head = shapes[start];
    var end = start + 1;
    while (end < shapes.len and alike(shapes[end], head)) end += 1;
    if (end > shapes.len) assert.panic("a group of shapes ran to {d}, past the {d} recorded; groupEnd() must stop at shapes.len, so check its while condition", .{ end, shapes.len });
    return end;
}

fn alike(a: Shape, b: Shape) bool {
    if (a.size < rules.min_twin_nodes or b.size < rules.min_twin_nodes) assert.panic("comparing shapes of {d} and {d} nodes; recordShape() keeps only shapes of {d} or more", .{ a.size, b.size, rules.min_twin_nodes });
    if (a.function == b.function and a.hash != b.hash) assert.panic("function {d} has two shapes; recordShape() records one per function", .{a.function});
    return a.hash == b.hash and a.size == b.size and a.is_test == b.is_test;
}

/// Same-shaped functions, or same-shaped tests, that make a cluster worth asking about.
pub const min_cluster = 3;
/// Members whose bodies go to TypeSafe; the rest are named by count.
const max_cluster_bodies = 3;

/// Adds a --infer unit for each cluster of `min_cluster` or more functions, or tests, of one
/// shape: the first few members' bodies to judge, and a fix naming the members and what varies.
pub fn clusterUnits(facts: *Facts, sources: Sources) error{LimitExceeded}!void {
    if (!facts.collect_units) assert.panic("building --infer clusters when units aren't collected; call clusterUnits() only under --infer", .{});
    const shapes = facts.shapes.items();
    std.mem.sort(Shape, shapes, {}, byShape);
    const before = facts.units.len;
    var start: usize = 0;
    while (start < shapes.len) {
        const end = groupEnd(shapes, start);
        defer start = end;
        if (end - start >= min_cluster) try clusterUnit(facts, sources, shapes[start..end]);
    }
    if (facts.units.len - before > shapes.len / min_cluster) assert.panic("made {d} clusters from {d} shapes; each takes at least {d}", .{ facts.units.len - before, shapes.len, min_cluster });
}

fn clusterUnit(facts: *Facts, sources: Sources, group: []const Shape) error{LimitExceeded}!void {
    if (group.len < min_cluster) assert.panic("a cluster of {d} shapes, under the {d} a cluster needs; clusterUnits() passes only groups that size or larger", .{ group.len, min_cluster });
    const lead = group[0];
    const functions = facts.functions.items();
    const first = functions[lead.function];
    const second = functions[group[1].function];
    const adapter = language.forPath(first.path) orelse assert.panic("{s} has a recorded shape but no language; recordShape() runs only on files a language checks", .{first.path});
    const text = facts.text;
    const source_start = text.used;
    for (group[0..@min(group.len, max_cluster_bodies)]) |shape| {
        const f = functions[shape.function];
        const body = bodyOf(sources.io, f.path, shape, sources.mine) orelse continue;
        _ = try text.format("=== {s}:{d} {s} ===\n{s}\n", .{ f.path, f.line + 1, f.name, body.bytes });
    }
    const source = text.buffer[source_start..text.used];
    if (source.len == 0) return;
    const fix_start = text.used;
    const more = group.len - 2;
    const kind = if (lead.is_test) (if (more == 1) "test" else "tests") else if (more == 1) "function" else "functions";
    _ = try text.format("'{s}' ({s}:{d}), '{s}' ({s}:{d})", .{ first.name, first.path, first.line + 1, second.name, second.path, second.line + 1 });
    if (more > 0) _ = try text.format(" and {d} more {s}", .{ more, kind });
    _ = try text.copy(" share one structure");
    const mine = bodyOf(sources.io, first.path, lead, sources.mine);
    const theirs = bodyOf(sources.io, second.path, group[1], sources.theirs);
    if (mine != null and theirs != null) switch (twins_module.compare(mine.?, theirs.?)) {
        .pairs => |pairs| if (pairs.len > 0) {
            _ = try text.format("; between the first two, ", .{});
            try pairs.write(text, " becomes ");
            _ = try text.copy(". What varies is what a builder, helper or table of cases would take; write the shared steps once, named in the domain's words.");
        },
        else => {},
    };
    if (text.used == fix_start) assert.panic("wrote no fix for the cluster of '{s}'; clusterUnit() names its members first", .{first.name});
    if (!std.mem.endsWith(u8, text.buffer[fix_start..text.used], ".")) _ = try text.copy(".");
    try facts.units.add(.{
        .kind = .cluster,
        .path = first.path,
        .language = adapter.name,
        .name = first.name,
        .line = first.line,
        .column = first.column,
        .end_line = first.line,
        .source = source,
        .fix = text.buffer[fix_start..text.used],
    });
}

/// Reports each function whose body has the same shape as another's, naming one of the others.
fn twins(facts: *Facts, findings: *memory.Bounded(Finding), sources: ?Sources) error{LimitExceeded}!void {
    const shapes = facts.shapes.items();
    const functions = facts.functions.items();
    std.mem.sort(Shape, shapes, {}, byShape);
    var start: usize = 0;
    while (start < shapes.len) {
        const end = groupEnd(shapes, start);
        defer start = end;
        const group = shapes[start..end];
        if (group.len < 2 or group[0].is_test) continue;
        for (group, 0..) |shape, i| {
            if (shape.function >= functions.len) assert.panic("a shape belongs to function {d}, but only {d} are recorded; commit() must offset each file's function numbers", .{ shape.function, functions.len });
            const f = functions[shape.function];
            const twin = group[if (i == 0) 1 else 0];
            const other = functions[twin.function];
            const fix: []const u8 = if (sources) |s| try differences(facts, s, shape, twin) orelse continue else "";
            try findings.add(.{
                .path = f.path,
                .line = f.line,
                .column = f.column,
                .rule = "structural-twins",
                .message = try facts.text.format("'{s}' has the same structure as '{s}' at {s}:{d}{s}, so a fix to one is probably needed in the other.", .{ f.name, other.name, other.path, other.line + 1, if (group.len > 2) try facts.text.format(" and {d} more", .{group.len - 2}) else "" }),
                .fix = fix,
            });
        }
    }
    if (start != shapes.len) assert.panic("structural-twins stopped at shape {d} of {d}; the grouping loop must reach the end", .{ start, shapes.len });
}

/// What `shape`'s body differs from `twin`'s in, read back from their files; empty when either
/// file can't be read again or has changed, and null when they only share a shape.
fn differences(facts: *Facts, sources: Sources, shape: Shape, twin: Shape) error{LimitExceeded}!?[]const u8 {
    const functions = facts.functions.items();
    if (shape.function == twin.function) assert.panic("comparing '{s}' with itself; twins() names a different function of the group as the twin", .{functions[shape.function].name});
    const mine = bodyOf(sources.io, functions[shape.function].path, shape, sources.mine) orelse return "";
    const theirs = bodyOf(sources.io, functions[twin.function].path, twin, sources.theirs) orelse return "";
    if (shape.hash != twin.hash) assert.panic("comparing '{s}' with '{s}', whose shapes differ; twins() compares only functions of one shape", .{ functions[shape.function].name, functions[twin.function].name });
    return twins_module.differenceFix(facts.text, mine, theirs, functions[twin.function].name);
}

/// The bytes of a recorded body, re-read from its file into `buffer`.
fn bodyOf(io: Io, path: []const u8, shape: Shape, buffer: []u8) ?twins_module.Body {
    if (shape.end <= shape.start) assert.panic("{s}: a shape spans bytes {d}..{d}; recordShape() records a body's start before its end", .{ path, shape.start, shape.end });
    if (buffer.len == 0) assert.panic("{s}: re-reading it into an empty buffer; Sources holds two buffers of the largest file size", .{path});
    const bytes = Io.Dir.cwd().readFile(io, path, buffer) catch return null;
    if (shape.end > bytes.len) return null;
    const adapter = language.forPath(path) orelse assert.panic("{s} has a recorded shape but no language; recordShape() runs only on files a language checks", .{path});
    return .{ .bytes = bytes[shape.start..shape.end], .line_comment = adapter.tables.line_comment };
}

/// Reports each function, method, class or type that nothing anywhere refers to by name, unless
/// code outside the module can use it, or a language or framework calls it by convention.
fn deadSymbols(facts: *Facts, findings: *memory.Bounded(Finding), scratch: ?*LiveScratch) error{LimitExceeded}!void {
    const before = findings.len;
    const references = facts.references.items();
    std.mem.sort(Reference, references, {}, Reference.before);
    var live = Liveness.initLiveness(facts.definitions.items(), scratch);
    live.propagate(references);
    for (facts.definitions.items()) |d| {
        if (d.public or !candidate(d)) continue;
        const hash = nameHash(d.name);
        const mentioned = mentions(references, hash);
        const dead = if (live.index(hash)) |i| !live.alive[i] else !mentioned;
        if (!dead) continue;
        const message = if (mentioned)
            try facts.text.format("'{s}' is {s} {s} that only unused code, or '{s}' itself, refers to, so it is code to read and maintain that never runs.", .{ d.name, article(d.kind), d.kind, d.name })
        else
            try facts.text.format("'{s}' is {s} {s} that nothing refers to, so it is code to read and maintain that never runs.", .{ d.name, article(d.kind), d.kind });
        try findings.add(.{ .path = d.path, .line = d.line, .column = d.column, .rule = "dead-symbol", .message = message });
    }
    if (references.len > 1 and Reference.before({}, references[references.len - 1], references[0])) assert.panic("the {d} references were not sorted before searching them; deadSymbols() must sort them first", .{references.len});
    if (findings.len - before > facts.definitions.len) assert.panic("dead-symbol reported {d} findings for {d} definitions; each definition can be reported once", .{ findings.len - before, facts.definitions.len });
}

/// Whether reachability decides if `d` is dead: a candidate no other file can import. Code another
/// file, or another project, may import counts as reachable, so a library's unused-looking API
/// doesn't make dead everything it uses.
fn traced(d: Definition) bool {
    if (d.name.len == 0) assert.panic("{s}:{d}: a definition has no name", .{ d.path, d.line + 1 });
    if (d.public and !d.importable and d.unmarked.len == 0 and d.kind.len == 0) assert.panic("{s}: '{s}' has no kind", .{ d.path, d.name });
    return !d.public and !d.importable and candidate(d);
}

/// "an" before a kind that starts with a vowel, such as "interface", else "a".
fn article(kind: []const u8) []const u8 {
    if (kind.len == 0) assert.panic("a definition has an empty kind; capture it as @definition.<kind>", .{});
    if (!std.ascii.isAlphabetic(kind[0])) assert.panic("the kind '{s}' doesn't start with a letter; kinds are words like 'function'", .{kind});
    const vowel = std.mem.indexOfScalar(u8, "aeiou", std.ascii.toLower(kind[0])) != null;
    return if (vowel) "an" else "a";
}

/// Whether any reference names `hash`; `sorted` is ordered by name.
fn mentions(sorted: []const Reference, hash: u64) bool {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle].name < hash) low = middle + 1 else high = middle;
    }
    if (low > sorted.len) assert.panic("searched {d} references and landed at {d}, past the end", .{ sorted.len, low });
    if (low > 0 and sorted[low - 1].name >= hash) assert.panic("the reference before position {d} is not below the name sought; sort the references by name first", .{low});
    return low < sorted.len and sorted[low].name == hash;
}

/// Which names only traced definitions have are reachable: referred to from module-level
/// code, or from inside a definition that is itself reachable, other than from themselves.
const Liveness = struct {
    names: []u64,
    alive: []bool,

    /// Traces nothing without scratch, so each name is then dead only when nothing mentions it.
    fn initLiveness(definitions: []const Definition, scratch: ?*LiveScratch) Liveness {
        const live = scratch orelse return .{ .names = &.{}, .alive = &.{} };
        if (live.candidates.len < definitions.len) assert.panic("room for {d} names, but the run holds {d} definitions; LiveScratch is sized from memory.Limits.definitions", .{ live.candidates.len, definitions.len });
        const all = live.candidates;
        const count = hashesOf(definitions, all, true);
        std.mem.sort(u64, all[0..count], {}, std.sort.asc(u64));
        // A name another definition shares, such as an importable one, can't be told apart by
        // hash, so only names traced definitions alone have are traced.
        const shared = live.others[0..hashesOf(definitions, live.others, false)];
        std.mem.sort(u64, shared, {}, std.sort.asc(u64));
        var kept: usize = 0;
        for (all[0..count]) |hash| {
            if (kept > 0 and all[kept - 1] == hash) continue;
            const at = firstAtLeast(shared, hash);
            if (at < shared.len and shared[at] == hash) continue;
            all[kept] = hash;
            kept += 1;
        }
        @memset(live.alive[0..kept], false);
        if (kept > count) assert.panic("kept {d} names from {d} candidates", .{ kept, count });
        return .{ .names = all[0..kept], .alive = live.alive[0..kept] };
    }

    fn index(self: *const Liveness, hash: u64) ?usize {
        if (self.alive.len != self.names.len) assert.panic("{d} names with {d} flags", .{ self.names.len, self.alive.len });
        const at = firstAtLeast(self.names, hash);
        if (at > self.names.len) assert.panic("looked up a name at {d} of {d}", .{ at, self.names.len });
        return if (at < self.names.len and self.names[at] == hash) at else null;
    }

    /// Whether a reference from inside `holder` keeps what it names alive: module-level code,
    /// and anything not traced here, always does.
    fn holds(self: *const Liveness, holder: u64) bool {
        if (self.alive.len != self.names.len) assert.panic("{d} names with {d} flags", .{ self.names.len, self.alive.len });
        if (holder == 0) return true;
        const i = self.index(holder) orelse return true;
        if (i >= self.alive.len) assert.panic("holder {d} indexed past {d} flags", .{ i, self.alive.len });
        return self.alive[i];
    }

    fn propagate(self: *Liveness, references: []const Reference) void {
        if (self.alive.len != self.names.len) assert.panic("{d} names with {d} flags", .{ self.names.len, self.alive.len });
        if (references.len > 1 and Reference.before({}, references[references.len - 1], references[0])) assert.panic("propagating over {d} unsorted references; sort them by name first", .{references.len});
        for (0..self.names.len + 1) |_| {
            var changed = false;
            for (references) |r| {
                const i = self.index(r.name) orelse continue;
                if (self.alive[i] or r.holder == r.name or !self.holds(r.holder)) continue;
                self.alive[i] = true;
                changed = true;
            }
            if (!changed) return;
        }
        assert.panic("liveness of {d} names was still changing after {d} passes; each pass marks at least one more", .{ self.names.len, self.names.len + 1 });
    }
};

/// The name hashes of the definitions reachability is traced for, or of all the others, into
/// `out`; returns how many.
fn hashesOf(definitions: []const Definition, out: []u64, traced_ones: bool) usize {
    if (out.len < definitions.len) assert.panic("room for {d} hashes from {d} definitions", .{ out.len, definitions.len });
    var count: usize = 0;
    for (definitions) |d| {
        if (traced(d) != traced_ones) continue;
        out[count] = nameHash(d.name);
        count += 1;
    }
    if (count > definitions.len) assert.panic("wrote {d} hashes from {d} definitions", .{ count, definitions.len });
    return count;
}

/// Where the first hash at least `hash` sits in `sorted`, or its length when there is none.
fn firstAtLeast(sorted: []const u64, hash: u64) usize {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle] < hash) low = middle + 1 else high = middle;
    }
    if (low > sorted.len) assert.panic("searched {d} hashes and landed at {d}, past the end; the search must stay within the slice", .{ sorted.len, low });
    if (low > 0 and sorted[low - 1] >= hash) assert.panic("the hash before position {d} is not below the one sought; sort the hashes before searching them", .{low});
    return low;
}

/// Whether nothing but a reference by name keeps `d` alive: not a test, an entry point, a dunder
/// name, or a method a protocol or interface fixes.
fn candidate(d: Definition) bool {
    if (d.name.len == 0) assert.panic("{s}:{d}: a definition has no name; the @name capture matched an empty node", .{ d.path, d.line + 1 });
    if (!check.contains(&.{ "function", "method", "class", "interface", "type", "macro" }, d.kind)) return false;
    if (std.mem.startsWith(u8, d.name, "__") and std.mem.endsWith(u8, d.name, "__")) return false;
    if (check.contains(&rules.entry_points, d.name)) return false;
    const adapter = language.named(d.language) orelse assert.panic("{s}: a definition was recorded in language '{s}', which zanity doesn't know; facts.language comes from the adapter that checked the file", .{ d.path, d.language });
    const t = adapter.tables;
    if (t.test_prefixes.len > 16) assert.panic("{s} lists {d} test prefixes; more than 16 means the table is wrong", .{ t.ecosystem, t.test_prefixes.len });
    for (t.test_prefixes) |prefix| if (std.mem.startsWith(u8, d.name, prefix)) return false;
    if (naming.testNamed(d.name)) return false;
    return !check.contains(t.protocol_names, d.name) and !check.contains(t.fixed_signatures, d.name);
}

/// Reports each interface, trait, protocol or abstract class that exactly one type implements.
fn singleImplementations(facts: *Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const implemented = facts.implemented.items();
    std.mem.sort(u64, implemented, {}, std.sort.asc(u64));
    const abstractions = facts.abstractions.items();
    std.mem.sort(Definition, abstractions, {}, Definition.sourceOrder);
    for (abstractions, 0..) |a, i| {
        if (i > 0 and abstractions[i - 1].line == a.line and std.mem.eql(u8, abstractions[i - 1].path, a.path)) continue;
        const hash = facts_module.typeHash(a.language, a.name);
        const first = firstAtLeast(implemented, hash);
        var count: usize = 0;
        while (first + count < implemented.len and implemented[first + count] == hash) count += 1;
        if (count != 1) continue;
        try findings.add(.{
            .path = a.path,
            .line = a.line,
            .column = a.column,
            .rule = "single-impl-abstraction",
            .message = try facts.text.format("'{s}' has only one implementation, so it adds a layer to read through without giving a choice of behaviour.", .{a.name}),
        });
        if (first + count > implemented.len) assert.panic("counted {d} implementations of '{s}' from {d}, past the {d} recorded; the counting loop must stop at the end", .{ count, a.name, first, implemented.len });
    }
    if (findings.len - before > abstractions.len) assert.panic("single-impl-abstraction reported {d} findings for {d} abstractions; each can be reported once", .{ findings.len - before, abstractions.len });
}
