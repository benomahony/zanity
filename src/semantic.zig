const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const vectors = @import("vectors.zig");
const Words = @import("words.zig").Words;
const store = @import("store.zig");

pub const default_thresholds: Thresholds = .{};
pub const Thresholds = struct {
    @"near-synonym": f64 = 0.95,
    @"context-outlier": f64 = 0.05,
    @"semantic-coupling": f64 = 0.92,
    @"intent-mismatch": f64 = 0.15,
};

pub const global_scope = "global";
const min_shared_prefix = 5;
const max_members = 8;

pub const Named = struct {
    name: []const u8,
    path: []const u8,
    line: u32 = 0,
    column: u32 = 0,
    scope: []const u8 = "",
    vector: []const f32,
    subject: store.Digest = @splat('0'),
};

pub const Coded = struct {
    name: []const u8,
    path: []const u8,
    line: u32 = 0,
    column: u32 = 0,
    scope: []const u8 = "",
    lines: u32 = 0,
    vector: []const f32,
    subject: store.Digest = @splat('0'),
};

pub const Described = struct {
    name: []const u8,
    path: []const u8,
    line: u32 = 0,
    column: u32 = 0,
    vectors: [3][]const f32,
    subject: store.Digest = @splat('0'),
};

pub const Insight = struct {
    rule: []const u8,
    path: []const u8,
    line: u32,
    column: u32,
    name: []const u8,
    message: []const u8,
    fix: []const u8 = "",
    score: f64,
    threshold: f64,
    subject: store.Digest,

    pub fn fired(self: Insight) bool {
        if (self.rule.len == 0) assert.panic("an insight about '{s}' has no rule", .{self.name});
        if (!(self.threshold > 0 and self.threshold <= 1)) assert.panic("{s} has a threshold of {d}; config keeps thresholds above 0 and at most 1", .{ self.rule, self.threshold });
        return self.score >= self.threshold;
    }
};

pub const Room = struct { parent: []u32, cluster: []u32, centroids: []f32, scores: []f32, refs: [][]const f32, text: *memory.Text };

const suffixes = [_][]const u8{ "ing", "ed", "es", "er", "y", "e" };

fn stem(word: []const u8) []const u8 {
    if (word.len == 0) assert.panic("stemming an empty word; Words never yields one", .{});
    for (suffixes) |s| if (word.len >= s.len + 3 and std.ascii.endsWithIgnoreCase(word, s)) return word[0 .. word.len - s.len];
    const plural = word.len >= 3 and std.ascii.toLower(word[word.len - 1]) == 's';
    if (plural and word.len < 3) assert.panic("'{s}' is too short to drop its s", .{word});
    return if (plural) word[0 .. word.len - 1] else word;
}

fn sameToken(whole_first: []const u8, whole_second: []const u8) bool {
    if (whole_first.len == 0 or whole_second.len == 0) assert.panic("comparing an empty word; Words never yields one", .{});
    const first = stem(whole_first);
    const second = stem(whole_second);
    if (std.ascii.eqlIgnoreCase(first, second)) return true;
    var shared: usize = 0;
    const common = @min(first.len, second.len);
    for (first[0..common], second[0..common]) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) break;
        shared += 1;
    }
    if (shared > first.len) assert.panic("'{s}' and '{s}' share {d} letters, more than either has", .{ first, second, shared });
    return shared >= min_shared_prefix or (shared == common and shared >= 3);
}

fn sharesAToken(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) assert.panic("comparing an empty name; definitions always have one", .{});
    if (first.ptr == second.ptr and first.len == second.len) assert.panic("comparing '{s}' with itself; a cluster lists each name once", .{first});
    var a: Words = .{ .text = first };
    for (0..first.len) |_| {
        const left = a.next() orelse return false;
        var b: Words = .{ .text = second };
        for (0..second.len) |_| {
            const right = b.next() orelse break;
            if (sameToken(left, right)) return true;
        }
    }
    assert.panic("'{s}' has more words than letters", .{first});
}

fn names(scratch: Room, items: []const Named) []const []const f32 {
    if (items.len > scratch.parent.len) assert.panic("{d} names in room for {d}", .{ items.len, scratch.parent.len });
    if (items.len > scratch.refs.len) assert.panic("no room to list {d} vectors", .{items.len});
    for (items, 0..) |item, i| scratch.refs[i] = item.vector;
    return scratch.refs[0..items.len];
}

fn synonyms(items: []const Named, cluster: []const u32, root: usize, members: *[max_members]usize) ?[]const usize {
    if (cluster.len != items.len) assert.panic("{d} cluster marks for {d} names", .{ cluster.len, items.len });
    if (cluster[root] != root) assert.panic("name {d} is not the root of its cluster", .{root});
    var count: usize = 0;
    for (items[root..], root..) |other, j| {
        if (cluster[j] != root) continue;
        for (members[0..@min(count, max_members)]) |m| if (sharesAToken(items[m].name, other.name)) return null;
        if (count < max_members) members[count] = j;
        count += 1;
    }
    return if (count < 2) null else members[0..@min(count, max_members)];
}

pub fn nearSynonyms(scratch: Room, items: []const Named, threshold: f64, out: *memory.Bounded(Insight)) !void {
    if (!(threshold > 0 and threshold <= 1)) assert.panic("near-synonym at a threshold of {d}", .{threshold});
    if (items.len < 2) return;
    if (items.len > scratch.cluster.len) assert.panic("{d} names in room for {d} cluster marks", .{ items.len, scratch.cluster.len });
    const cluster = scratch.cluster[0..items.len];
    vectors.clusters(names(scratch, items), @floatCast(threshold), scratch.parent[0..items.len], cluster);
    for (items, 0..) |first, i| {
        if (cluster[i] != i) continue;
        var members: [max_members]usize = undefined;
        const kept = synonyms(items, cluster, i, &members) orelse continue;
        var sum: f64 = 0;
        var pairs: f64 = 0;
        for (kept, 0..) |a, x| for (kept[x + 1 ..]) |b| {
            sum += vectors.cosine(items[a].vector, items[b].vector);
            pairs += 1;
        };
        const start = scratch.text.used;
        for (kept, 0..) |m, x| _ = try scratch.text.format("{s}'{s}'", .{ if (x == 0) "" else if (x + 1 == kept.len) " and " else ", ", items[m].name });
        const listed = scratch.text.buffer[start..scratch.text.used];
        const score = sum / pairs;
        try out.add(.{ .rule = "near-synonym", .path = first.path, .line = first.line, .column = first.column, .name = first.name, .score = score, .threshold = threshold, .subject = first.subject, .message = try scratch.text.format("{s} name the same idea in unrelated words (mean cosine {d:.2}).", .{ listed, score }) });
    }
}

fn scopeName(item: Named) []const u8 {
    if (item.name.len == 0) assert.panic("{s}: a name with no text", .{item.path});
    const scope = if (item.scope.len == 0) global_scope else item.scope;
    if (scope.len == 0) assert.panic("'{s}' has no scope to group by", .{item.name});
    return scope;
}

pub fn contextOutliers(scratch: Room, items: []const Named, margin: f64, out: *memory.Bounded(Insight)) !void {
    if (!(margin > 0 and margin <= 1)) assert.panic("context-outlier at a margin of {d}", .{margin});
    if (items.len == 0) return;
    const dims = items[0].vector.len;
    var labels: [33][]const u8 = undefined;
    var count: usize = 0;
    const home = scratch.cluster[0..items.len];
    for (items, home) |item, *h| {
        const scope = scopeName(item);
        h.* = for (labels[0..count], 0..) |l, c| {
            if (std.mem.eql(u8, l, scope)) break @intCast(c);
        } else @intCast(count);
        if (h.* < count) continue;
        if (count == labels.len) return;
        labels[count] = scope;
        count += 1;
    }
    if (count < 2) return;
    if (scratch.centroids.len < count * dims) assert.panic("no room for {d} centroids of {d} values", .{ count, dims });
    var centroids: [33][]const f32 = undefined;
    for (0..count) |c| {
        const sum = scratch.centroids[c * dims ..][0..dims];
        @memset(sum, 0);
        for (items, home) |item, h| if (h == c) for (sum, item.vector) |*s, v| {
            s.* += v;
        };
        vectors.normalise(sum);
        centroids[c] = sum;
    }
    for (items, home) |item, at| {
        const best = vectors.nearest(item.vector, centroids[0..count]);
        if (best.index == at) continue;
        const score: f64 = best.score - vectors.cosine(item.vector, centroids[at]);
        try out.add(.{ .rule = "context-outlier", .path = item.path, .line = item.line, .column = item.column, .name = item.name, .score = score, .threshold = margin, .subject = item.subject, .message = try scratch.text.format("'{s}' reads like {s} vocabulary but lives in {s} ({d:.2} nearer {s}'s centroid).", .{ item.name, labels[best.index], labels[at], score, labels[best.index] }) });
    }
}

fn before(a: Coded, b: Coded) bool {
    if (a.path.len == 0 or b.path.len == 0) assert.panic("ordering bodies with no path; facts.unit() records every function's file", .{});
    const order = std.mem.order(u8, a.path, b.path);
    if (order == .eq and a.line == b.line and std.mem.eql(u8, a.name, b.name)) assert.panic("ordering '{s}' against itself; a body's nearest is always another", .{a.name});
    return order == .lt or (order == .eq and a.line < b.line);
}

pub fn semanticCoupling(scratch: Room, items: []const Coded, threshold: f64, out: *memory.Bounded(Insight)) !void {
    if (!(threshold > 0 and threshold <= 1)) assert.panic("semantic-coupling at a threshold of {d}", .{threshold});
    if (items.len > scratch.parent.len) assert.panic("{d} bodies in room for {d}", .{ items.len, scratch.parent.len });
    const best = scratch.parent[0..items.len];
    const scores = scratch.scores[0..items.len];
    for (items, 0..) |a, i| {
        best[i] = @intCast(i);
        scores[i] = -1;
        for (items, 0..) |b, j| {
            if (i == j or (std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.scope, b.scope))) continue;
            const s = vectors.cosine(a.vector, b.vector);
            if (s <= scores[i]) continue;
            scores[i] = s;
            best[i] = @intCast(j);
        }
    }
    for (items, 0..) |a, i| {
        const j = best[i];
        if (j == i) continue;
        const b = items[j];
        if (best[j] == i and before(b, a)) continue;
        try out.add(.{ .rule = "semantic-coupling", .path = a.path, .line = a.line, .column = a.column, .name = a.name, .score = scores[i], .threshold = threshold, .subject = a.subject, .message = try scratch.text.format("'{s}' does what '{s}' in {s}:{d} does (cosine {d:.2}), though their code differs.", .{ a.name, b.name, b.path, b.line + 1, scores[i] }) });
    }
}

const parts = [3][]const u8{ "name", "docstring", "body" };

pub fn intentMismatch(scratch: Room, items: []const Described, margin: f64, out: *memory.Bounded(Insight)) !void {
    if (!(margin > 0 and margin <= 1)) assert.panic("intent-mismatch at a margin of {d}", .{margin});
    if (items.len > 0 and items[0].vectors[0].len == 0) assert.panic("'{s}' has a name vector with no values", .{items[0].name});
    for (items) |item| {
        var odd: usize = 0;
        var score: f64 = -2;
        for (0..3) |x| {
            const a = item.vectors[(x + 1) % 3];
            const b = item.vectors[(x + 2) % 3];
            const s: f64 = vectors.cosine(a, b) - @max(vectors.cosine(item.vectors[x], a), vectors.cosine(item.vectors[x], b));
            if (s <= score) continue;
            score = s;
            odd = x;
        }
        const message = try scratch.text.format("'{s}': its {s} disagrees with its {s} and {s}, which agree with each other ({d:.2} apart).", .{ item.name, parts[odd], parts[(odd + 1) % 3], parts[(odd + 2) % 3], score });
        const fix = switch (odd) {
            0 => "Rename it to say what its docstring and body say it does.",
            1 => "Update the docstring to say what the name and body say it does.",
            else => "Check the body does what its name and docstring promise, and fix whichever is wrong.",
        };
        try out.add(.{ .rule = "intent-mismatch", .path = item.path, .line = item.line, .column = item.column, .name = item.name, .score = score, .threshold = margin, .subject = item.subject, .message = message, .fix = fix });
    }
}

const east = [_]f32{ 1, 0 };
const east_ish = [_]f32{ 0.96, 0.28 };
const north = [_]f32{ 0, 1 };

const Fixture = struct {
    parent: [8]u32 = undefined,
    cluster: [8]u32 = undefined,
    centroids: [64]f32 = undefined,
    scores: [8]f32 = undefined,
    refs: [8][]const f32 = undefined,
    bytes: [2048]u8 = undefined,
    text: memory.Text = undefined,
    found: [8]Insight = undefined,
    insights: memory.Bounded(Insight) = undefined,

    fn scratch(self: *Fixture) Room {
        if (self.bytes.len == 0 or self.found.len == 0) assert.panic("a fixture with no room for insights", .{});
        self.text = .{ .buffer = &self.bytes };
        if (self.text.used != 0) assert.panic("a fresh fixture has {d} bytes of text in use", .{self.text.used});
        self.insights = .{ .buffer = &self.found, .what = "insights" };
        return .{ .parent = &self.parent, .cluster = &self.cluster, .centroids = &self.centroids, .scores = &self.scores, .refs = &self.refs, .text = &self.text };
    }

    fn fired(self: *Fixture) usize {
        if (self.insights.len > self.found.len) assert.panic("{d} insights in room for {d}", .{ self.insights.len, self.found.len });
        var count: usize = 0;
        for (self.insights.items()) |i| count += @intFromBool(i.fired());
        if (count > self.insights.len) assert.panic("{d} of {d} insights fired", .{ count, self.insights.len });
        return count;
    }
};

fn named(name: []const u8, vector: []const f32) Named {
    if (name.len == 0) assert.panic("a test name with no text", .{});
    if (vector.len != 2) assert.panic("'{s}' has {d} values; the tests use two", .{ name, vector.len });
    return .{ .name = name, .path = "src/core/a.py", .vector = vector };
}

test "near-synonym reports close names that share no word" {
    var f: Fixture = .{};
    try nearSynonyms(f.scratch(), &.{ named("fetch_order", &east), named("retrieve_purchase", &east_ish) }, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.fired());
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), f.found[0].score, 1e-6);
    try std.testing.expectEqualStrings("'fetch_order' and 'retrieve_purchase' name the same idea in unrelated words (mean cosine 0.96).", f.found[0].message);
}

test "near-synonym ignores names that already share a word" {
    var f: Fixture = .{};
    try nearSynonyms(f.scratch(), &.{ named("fetch_order", &east), named("order_fetcher", &east_ish) }, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "near-synonym ignores distant names" {
    var f: Fixture = .{};
    try nearSynonyms(f.scratch(), &.{ named("fetch_order", &east), named("send_invoice", &north) }, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "near-synonym takes a plural or a longer form of a word as the same word" {
    var f: Fixture = .{};
    try nearSynonyms(f.scratch(), &.{ named("Definition", &east), named("definitions", &east_ish) }, 0.9, &f.insights);
    try nearSynonyms(f.scratch(), &.{ named("Embeddings", &east), named("_embedder", &east_ish), named("embed_names", &.{ 0.97, 0.24 }) }, 0.9, &f.insights);
    try nearSynonyms(f.scratch(), &.{ named("_alias_map", &east), named("map_points", &east_ish) }, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "near-synonym takes an inflection of a short word as the same word" {
    var f: Fixture = .{};
    try nearSynonyms(f.scratch(), &.{ named("fit", &east), named("fits", &east_ish) }, 0.9, &f.insights);
    try nearSynonyms(f.scratch(), &.{ named("calling", &east), named("calls", &east_ish) }, 0.9, &f.insights);
    try nearSynonyms(f.scratch(), &.{ named("id", &east), named("ids", &east_ish) }, 0.9, &f.insights);
    try nearSynonyms(f.scratch(), &.{ named("Reading", &east), named("reads", &east_ish) }, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "near-synonym scores a cluster by its mean cosine, not its weakest pair" {
    var f: Fixture = .{};
    try nearSynonyms(f.scratch(), &.{ named("fetch", &east), named("retrieve", &east_ish), named("collect", &.{ 0.9, 0.44 }) }, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.insights.len);
    try std.testing.expect(f.found[0].score > 0.9 and f.found[0].score < 1.0);
}

fn inContext(name: []const u8, scope: []const u8, vector: []const f32) Named {
    if (name.len == 0 or scope.len == 0) assert.panic("a test name '{s}' in scope '{s}'; give both", .{ name, scope });
    if (vector.len != 2) assert.panic("'{s}' has {d} values; the tests use two", .{ name, vector.len });
    return .{ .name = name, .path = "src/a.py", .scope = scope, .vector = vector };
}

test "context-outlier reports a name nearer another context's centroid than its own" {
    var f: Fixture = .{};
    try contextOutliers(f.scratch(), &.{ inContext("Invoice", "billing", &east), inContext("InvoiceLine", "billing", &east_ish), inContext("Order", "core", &north), inContext("InvoiceTotal", "core", &.{ 0.98, 0.2 }) }, 0.05, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.fired());
    try std.testing.expectEqualStrings("InvoiceTotal", f.found[0].name);
    try std.testing.expect(std.mem.indexOf(u8, f.found[0].message, "billing vocabulary but lives in core") != null);
}

test "context-outlier stays quiet when each name sits in its own context" {
    var f: Fixture = .{};
    try contextOutliers(f.scratch(), &.{ inContext("Invoice", "billing", &east), inContext("Order", "core", &north) }, 0.05, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "context-outlier needs at least two contexts" {
    var f: Fixture = .{};
    try contextOutliers(f.scratch(), &.{ inContext("Invoice", "billing", &east), inContext("Order", "billing", &north) }, 0.05, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "semantic-coupling pairs bodies in different files once, at the first" {
    var f: Fixture = .{};
    const bodies = [_]Coded{ .{ .name = "charge", .path = "a.py", .vector = &east }, .{ .name = "bill", .path = "b.py", .vector = &east_ish }, .{ .name = "ship", .path = "c.py", .vector = &north } };
    try semanticCoupling(f.scratch(), &bodies, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.fired());
    try std.testing.expectEqualStrings("charge", f.found[0].name);
}

test "semantic-coupling leaves bodies in the same file to structural rules" {
    var f: Fixture = .{};
    const bodies = [_]Coded{ .{ .name = "charge", .path = "a.py", .vector = &east }, .{ .name = "bill", .path = "a.py", .vector = &east_ish } };
    try semanticCoupling(f.scratch(), &bodies, 0.9, &f.insights);
    try std.testing.expectEqual(@as(usize, 0), f.insights.len);
}

test "intent-mismatch names the one of name, docstring and body that disagrees" {
    var f: Fixture = .{};
    const described = [_]Described{ .{ .name = "send_invoice", .path = "a.py", .vectors = .{ &north, &east, &east_ish } }, .{ .name = "charge", .path = "a.py", .vectors = .{ &east, &east_ish, &.{ 0.98, 0.2 } } } };
    try intentMismatch(f.scratch(), &described, 0.15, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.fired());
    try std.testing.expect(std.mem.indexOf(u8, f.found[0].message, "its name disagrees with its docstring and body") != null);
}
