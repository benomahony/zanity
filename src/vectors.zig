const std = @import("std");
const assert = @import("assert.zig");

pub fn normalise(vector: []f32) void {
    if (vector.len == 0) assert.panic("normalising a vector with no values; the server must return at least one per text", .{});
    var sum: f64 = 0;
    for (vector) |v| sum += @as(f64, v) * v;
    if (std.math.isNan(sum)) assert.panic("normalising a {d}-value vector whose squares sum to {d}; the server returned an invalid embedding", .{ vector.len, sum });
    if (sum == 0) return;
    const scale: f32 = @floatCast(1 / @sqrt(sum));
    for (vector) |*v| v.* *= scale;
}

pub fn cosine(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) assert.panic("comparing a {d}-value vector with a {d}-value one; every vector of a run comes from one model, so check [embed] model", .{ a.len, b.len });
    if (a.len == 0) assert.panic("comparing vectors with no values; the server must return at least one per text", .{});
    var dot: f64 = 0;
    var aa: f64 = 0;
    var bb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * y;
        aa += @as(f64, x) * x;
        bb += @as(f64, y) * y;
    }
    if (aa == 0 or bb == 0) return 0;
    return @floatCast(dot / @sqrt(aa * bb));
}

pub fn centroid(members: []const []const f32, out: []f32) void {
    if (members.len == 0) assert.panic("a centroid of no vectors; group at least one name before taking its centroid", .{});
    if (out.len != members[0].len) assert.panic("writing a {d}-value centroid of {d}-value vectors; size the buffer to the vectors", .{ out.len, members[0].len });
    @memset(out, 0);
    for (members) |member| {
        var sum: f64 = 0;
        for (member) |v| sum += @as(f64, v) * v;
        if (sum == 0) continue;
        const scale: f32 = @floatCast(1 / @sqrt(sum));
        for (out, member) |*o, v| o.* += v * scale;
    }
    normalise(out);
}

pub fn nearest(vector: []const f32, centroids: []const []const f32) struct { index: usize, score: f32 } {
    if (centroids.len == 0) assert.panic("finding the nearest of no centroids; context-outlier needs at least two contexts", .{});
    var best: usize = 0;
    var score = cosine(vector, centroids[0]);
    for (centroids[1..], 1..) |c, i| {
        const s = cosine(vector, c);
        if (s > score) {
            best = i;
            score = s;
        }
    }
    if (best >= centroids.len) assert.panic("chose centroid {d} of {d}", .{ best, centroids.len });
    return .{ .index = best, .score = score };
}

fn root(parent: []u32, index: u32) u32 {
    if (index >= parent.len) assert.panic("finding the root of vector {d} of {d}", .{ index, parent.len });
    if (parent[index] >= parent.len) assert.panic("vector {d} points at {d}, past the {d} clustered", .{ index, parent[index], parent.len });
    var at = index;
    for (0..parent.len) |_| {
        if (parent[at] == at) return at;
        parent[at] = parent[parent[at]];
        at = parent[at];
    }
    assert.panic("the cluster of vector {d} has no root after {d} steps; join() must only point a root at another root", .{ index, parent.len });
}

pub fn clusters(vectors: []const []const f32, threshold: f32, parent: []u32, cluster: []u32) void {
    if (!(threshold >= 0 and threshold <= 1)) assert.panic("clustering at a threshold of {d}; a threshold is a cosine between 0 and 1", .{threshold});
    if (parent.len != vectors.len or cluster.len != vectors.len) assert.panic("clustering {d} vectors with {d} parents and {d} cluster slots; size both to the vectors", .{ vectors.len, parent.len, cluster.len });
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (vectors, 0..) |a, i| for (vectors[i + 1 ..], i + 1..) |b, j| {
        if (cosine(a, b) < threshold) continue;
        const x = root(parent, @intCast(i));
        const y = root(parent, @intCast(j));
        if (x != y) parent[@max(x, y)] = @min(x, y);
    };
    for (cluster, 0..) |*c, i| c.* = root(parent, @intCast(i));
}

const right = [_]f32{ 1, 0 };
const right_ish = [_]f32{ 0.96, 0.28 };
const up = [_]f32{ 0, 1 };

test "cosines compare direction, not length" {
    const twice = [_]f32{ 2, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosine(&right, &right), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosine(&right, &up), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosine(&right, &twice), 1e-6);
}

test "a zero vector has no direction, so its cosine with anything is 0" {
    const zero = [_]f32{ 0, 0 };
    try std.testing.expectEqual(@as(f32, 0), cosine(&zero, &zero));
}

test "clusters group vectors above the threshold only" {
    var parent: [3]u32 = undefined;
    var cluster: [3]u32 = undefined;
    clusters(&.{ &right, &right_ish, &up }, 0.9, &parent, &cluster);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 2 }, &cluster);
    clusters(&.{ &right, &right_ish, &up }, 0.99, &parent, &cluster);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, &cluster);
}

test "clusters link transitively, so a chain of close pairs is one cluster" {
    const further = [_]f32{ 0.85, 0.53 };
    var parent: [3]u32 = undefined;
    var cluster: [3]u32 = undefined;
    clusters(&.{ &right, &right_ish, &further }, 0.9, &parent, &cluster);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, &cluster);
}

test "a centroid is the mean of the unit vectors" {
    const a = [_]f32{ 3, 0 };
    const b = [_]f32{ 0, 3 };
    var out: [2]f32 = undefined;
    centroid(&.{ &a, &b }, &out);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(0.5)), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(0.5)), out[1], 1e-6);
}

test "nearest picks the closest centroid" {
    const found = nearest(&right, &.{ &right_ish, &up });
    try std.testing.expectEqual(@as(usize, 0), found.index);
    try std.testing.expectApproxEqAbs(@as(f32, 0.96), found.score, 1e-6);
}
