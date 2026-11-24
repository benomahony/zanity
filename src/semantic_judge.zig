const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const store = @import("store.zig");
const store_vectors = @import("store_vectors.zig");
const embed = @import("embed.zig");
const rules = @import("rules.zig");
const strings = @import("strings.zig");
const semantic = @import("semantic.zig");
const intent = @import("intent.zig");
const facts_module = @import("facts.zig");
const Unit = facts_module.Unit;
const Definition = facts_module.Definition;
const Finding = facts_module.Finding;
const Allocator = std.mem.Allocator;

pub const Embedded = struct {
    units: []const Unit,
    definitions: []const Definition,
    findings: *memory.Bounded(Finding),
    enabled: rules.Set,
    thresholds: semantic.Thresholds,
};

const Judging = struct {
    named: memory.Bounded(semantic.Named),
    bodies: memory.Bounded(semantic.Coded),
    described: memory.Bounded(intent.Described),
    insights: memory.Bounded(semantic.Insight),
    seen: std.DynamicBitSetUnmanaged,
    centroids: []f32,
    scores: []f32,
    refs: [][]const f32,

    fn initJudging(gpa: Allocator, texts: usize, dimensions: usize) !Judging {
        if (texts == 0 or dimensions == 0) assert.panic("judging {d} texts of {d} values; judge() returns before when nothing was embedded", .{ texts, dimensions });
        const judging: Judging = .{
            .named = try .initBounded(gpa, texts, "names to compare"),
            .bodies = try .initBounded(gpa, texts, "bodies to compare"),
            .described = try .initBounded(gpa, texts, "documented functions to compare"),
            .insights = try .initBounded(gpa, 4 * texts, "embedding insights"),
            .seen = try .initEmpty(gpa, texts),
            .centroids = &.{},
            .scores = try memory.reserveUninitialized(gpa, f32, texts),
            .refs = try memory.reserveUninitialized(gpa, []const f32, texts),
        };
        if (judging.scores.len != texts) assert.panic("reserved {d} scores for {d} texts", .{ judging.scores.len, texts });
        return judging;
    }
};

fn twinned(findings: []const Finding, unit: *const Unit) bool {
    if (unit.end_line < unit.line) assert.panic("{s}: '{s}' ends before it starts; facts.unit() records its first line first", .{ unit.path, unit.name });
    const found = for (findings) |f| {
        if (std.mem.eql(u8, f.rule, "structural-twins") and std.mem.eql(u8, f.path, unit.path) and f.line >= unit.line and f.line <= unit.end_line) break true;
    } else false;
    if (found and findings.len == 0) assert.panic("found a twin among no findings", .{});
    return found;
}

/// Gathers the bodies semantic-coupling compares and the functions intent-mismatch reads. A
/// function a framework or the operating system calls by a fixed name, such as `main`, has a
/// name its author didn't choose, which says nothing for its docstring and body to agree with.
fn collectFunctions(e: *const embed.Embedding, j: *Judging, settled: []const Finding) error{LimitExceeded}!void {
    if (e.dimensions == 0) assert.panic("collecting {d} functions to compare before any vector was fetched; fetch() runs first", .{e.units.len});
    const before = j.bodies.len + j.described.len;
    for (e.units.items()) |row| {
        const u = row.unit;
        const subject = e.entryHash(row.body);
        if (u.kind != .@"test" and u.end_line - u.line + 1 >= rules.min_twin_lines and !twinned(settled, u)) try j.bodies.add(.{ .name = u.name, .path = u.path, .line = u.line, .column = u.column, .vector = e.vector(row.body), .subject = subject, .source = u.source });
        const doc = row.doc orelse continue;
        if (strings.contains(&rules.entry_points, u.name)) continue;
        try j.described.add(.{ .name = u.name, .path = u.path, .line = u.line, .column = u.column, .vectors = .{ e.vector(row.name), e.vector(doc), e.vector(row.body) }, .doc = embed.docOf(u.source), .subject = subject });
    }
    if (j.bodies.len + j.described.len - before > 2 * e.units.len) assert.panic("collected {d} functions to compare from {d}; each is added at most once to each list", .{ j.bodies.len + j.described.len - before, e.units.len });
}

pub fn judge(e: *embed.Embedding, run: Embedded) !void {
    if (run.enabled.len == 0) assert.panic("judging embeddings with no rules enabled; a check enables at least one", .{});
    if (e.entries.len != 0) assert.panic("judging {d} texts collected before; judge() collects them", .{e.entries.len});
    try e.collect(run.units, run.definitions);
    try e.fetch();
    if (!e.judging or e.dimensions == 0 or e.entries.len == 0) return;
    var j = try Judging.initJudging(e.gpa, e.entries.len, e.dimensions);
    j.centroids = try memory.reserveUninitialized(e.gpa, f32, @max(semantic.max_contexts * e.dimensions, e.entries.len));
    for (e.names.items()) |row| {
        if (j.seen.isSet(row.name)) continue;
        j.seen.set(row.name);
        const d = row.definition;
        try j.named.add(.{ .name = d.name, .path = d.path, .line = d.line, .column = d.column, .scope = d.scope, .vector = e.vector(row.name), .subject = e.entryHash(row.name) });
    }
    try collectFunctions(e, &j, run.findings.items());
    const scratch: semantic.Room = .{ .parent = e.parent, .cluster = e.cluster, .centroids = j.centroids, .scores = j.scores, .refs = j.refs, .text = &e.text };
    const t = run.thresholds;
    if (run.enabled.enabled("near-synonym")) try semantic.nearSynonyms(scratch, j.named.items(), t.@"near-synonym", &j.insights);
    if (run.enabled.enabled("context-outlier")) try semantic.contextOutliers(scratch, j.named.items(), t.@"context-outlier", &j.insights);
    if (run.enabled.enabled("semantic-coupling")) try semantic.semanticCoupling(scratch, j.bodies.items(), t.@"semantic-coupling", &j.insights);
    if (run.enabled.enabled("intent-mismatch")) try intent.intentMismatch(scratch, j.described.items(), t.@"intent-mismatch", &j.insights);
    try report(e, j.insights.items(), run.findings);
}

fn report(e: *embed.Embedding, insights: []const semantic.Insight, findings: *memory.Bounded(Finding)) !void {
    if (e.model.len == 0) assert.panic("observing embedding rules under no model; initEmbedding() names it", .{});
    const before = findings.len;
    try store_vectors.batched(&e.store, .begin);
    for (insights) |i| {
        const p = std.math.clamp(i.score, 0, 1);
        const fired = p >= i.threshold;
        try e.store.observe(.{ .path = i.path, .rule = i.rule, .unit = i.subject, .unit_name = i.name, .line = i.line + 1, .language = "", .model = e.model, .question = store.digest(&.{i.rule}), .probability = p, .threshold = i.threshold, .fired = fired });
        if (!fired or try e.store.labelled(i.rule, i.subject) == false) continue;
        try findings.add(.{ .path = i.path, .line = i.line, .column = i.column, .rule = i.rule, .message = i.message, .fix = i.fix });
    }
    try store_vectors.batched(&e.store, .commit);
    if (findings.len - before > insights.len) assert.panic("{d} findings from {d} insights", .{ findings.len - before, insights.len });
}
