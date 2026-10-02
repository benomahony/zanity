//! Cross-file checks of what the code is made of: functions with the same structure, definitions
//! nothing refers to, and abstractions with only one implementation.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const language = @import("language.zig");
const check = @import("check.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;
const Shape = facts_module.Shape;
const Definition = facts_module.Definition;
const nameHash = facts_module.nameHash;

pub fn checkStructure(facts: *Facts, enabled: rules.Set, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    if (enabled.len == 0) assert.panic("cross-file structure checks ran with no rules enabled; runCheck always enables at least one", .{});
    const before = findings.len;
    if (enabled.enabled("structural-twins")) try twins(facts, findings);
    if (enabled.enabled("dead-symbol")) try deadSymbols(facts, findings);
    if (enabled.enabled("single-impl-abstraction")) try singleImplementations(facts, findings);
    if (findings.len < before) assert.panic("cross-file structure checks dropped findings from {d} to {d}; they may only add", .{ before, findings.len });
}

fn byShape(_: void, a: Shape, b: Shape) bool {
    if (a.size == 0 or b.size == 0) assert.panic("sorting a function shape of no nodes; recordShape() keeps only shapes of min_twin_nodes or more", .{});
    if (a.function == b.function and a.hash != b.hash) assert.panic("function {d} has two shapes; recordShape() records one per function", .{a.function});
    if (a.hash != b.hash) return a.hash < b.hash;
    return a.function < b.function;
}

/// Reports each function whose body has the same shape as another's, naming one of the others.
fn twins(facts: *Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const shapes = facts.shapes.items();
    const functions = facts.functions.items();
    std.mem.sort(Shape, shapes, {}, byShape);
    var start: usize = 0;
    while (start < shapes.len) {
        var end = start + 1;
        while (end < shapes.len and shapes[end].hash == shapes[start].hash and shapes[end].size == shapes[start].size) end += 1;
        defer start = end;
        const group = shapes[start..end];
        if (group.len < 2) continue;
        for (group, 0..) |shape, i| {
            if (shape.function >= functions.len) assert.panic("a shape belongs to function {d}, but only {d} are recorded; commit() must offset each file's function numbers", .{ shape.function, functions.len });
            const f = functions[shape.function];
            const other = functions[group[if (i == 0) 1 else 0].function];
            try findings.add(.{
                .path = f.path,
                .line = f.line,
                .column = f.column,
                .rule = "structural-twins",
                .message = try facts.text.format("'{s}' has the same structure as '{s}' at {s}:{d}{s}, so a fix to one is probably needed in the other.", .{ f.name, other.name, other.path, other.line + 1, if (group.len > 2) try facts.text.format(" and {d} more", .{group.len - 2}) else "" }),
            });
        }
    }
    if (start != shapes.len) assert.panic("structural-twins stopped at shape {d} of {d}; the grouping loop must reach the end", .{ start, shapes.len });
}

/// Reports each function, method, class or type that nothing anywhere refers to by name, unless
/// code outside the module can use it, or a language or framework calls it by convention.
fn deadSymbols(facts: *Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const before = findings.len;
    const references = facts.references.items();
    std.mem.sort(u64, references, {}, std.sort.asc(u64));
    for (facts.definitions.items()) |d| {
        if (d.public or !candidate(d)) continue;
        const hash = nameHash(d.name);
        const at = firstAtLeast(references, hash);
        if (at < references.len and references[at] == hash) continue;
        try findings.add(.{
            .path = d.path,
            .line = d.line,
            .column = d.column,
            .rule = "dead-symbol",
            .message = try facts.text.format("'{s}' is a {s} that nothing refers to, so it is code to read and maintain that never runs.", .{ d.name, d.kind }),
        });
    }
    if (references.len > 1 and references[0] > references[references.len - 1]) assert.panic("the {d} references were not sorted before searching them; deadSymbols() must sort them first", .{references.len});
    if (findings.len - before > facts.definitions.len) assert.panic("dead-symbol reported {d} findings for {d} definitions; each definition can be reported once", .{ findings.len - before, facts.definitions.len });
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
