const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const n = 1 << 20;
const runs = 5;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();

    const values = try gpa.alloc(u64, n);
    for (values, 0..) |*v, i| v.* = i;

    std.debug.print("{s:<24} {s:>12} {s:>12} {s:>8}   {s}\n", .{ "rule", "before", "after", "speedup", "memory" });

    try report(io, "allocation-in-loop", allocateEachPass, .{ gpa, values }, allocateOnce, .{ gpa, values }, "");

    const lines = try gpa.alloc([]const u8, n);
    for (lines, 0..) |*line, i| line.* = if (i % 7 == 0) "the quick brown fox" else "jumps over the lazy dog";
    try report(io, "invariant-in-loop", trimEachPass, .{ lines, "  fox  " }, trimOnce, .{ lines, "  fox  " }, "");

    const nodes = try gpa.alloc(Node, n);
    const boxed = try gpa.alloc(*Node, n);
    for (nodes, boxed, 0..) |*node, *box, i| {
        node.* = .{ .id = i, .weight = i % 13 };
        box.* = try gpa.create(Node);
        box.*.* = node.*;
    }
    random.shuffle(*Node, boxed);
    try report(io, "pointer-collection", sumBoxed, .{boxed}, sumFlat, .{nodes}, try std.fmt.allocPrint(gpa, "{d} MB + {d} allocations vs {d} MB", .{ n * (8 + @sizeOf(Node)) / 1_000_000, n, n * @sizeOf(Node) / 1_000_000 }));

    const padded = try gpa.alloc(Padded, n);
    const ordered = try gpa.alloc(Ordered, n);
    for (padded, ordered, 0..) |*p, *o, i| {
        p.* = .{ .ready = i % 2 == 0, .count = i, .small = i % 3 == 0 };
        o.* = .{ .count = i, .ready = i % 2 == 0, .small = i % 3 == 0 };
    }
    try report(io, "padded-struct", sumPadded, .{padded}, sumOrdered, .{ordered}, try std.fmt.allocPrint(gpa, "{d} MB vs {d} MB ({d} B vs {d} B each)", .{ n * @sizeOf(Padded) / 1_000_000, n * @sizeOf(Ordered) / 1_000_000, @sizeOf(Padded), @sizeOf(Ordered) }));

    const wide = try gpa.alloc(Wide, n);
    const balances = try gpa.alloc(f64, n);
    for (wide, balances, 0..) |*w, *b, i| {
        w.* = std.mem.zeroes(Wide);
        w.balance = @floatFromInt(i);
        b.* = w.balance;
    }
    try report(io, "wide-hot-struct", sumWide, .{wide}, sumBalances, .{balances}, try std.fmt.allocPrint(gpa, "reads {d} B per element vs 8 B", .{@sizeOf(Wide)}));
}

fn report(io: Io, rule: []const u8, comptime before: anytype, before_args: anytype, comptime after: anytype, after_args: anytype, memory: []const u8) !void {
    const slow = try fastest(io, before, before_args);
    const fast = try fastest(io, after, after_args);
    const ms: f64 = std.time.ns_per_ms;
    std.debug.print("{s:<24} {d:>9.2} ms {d:>9.2} ms {d:>7.2}x   {s}\n", .{ rule, @as(f64, @floatFromInt(slow)) / ms, @as(f64, @floatFromInt(fast)) / ms, @as(f64, @floatFromInt(slow)) / @as(f64, @floatFromInt(fast)), memory });
}

fn fastest(io: Io, comptime work: anytype, args: anytype) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        const start = Io.Timestamp.now(io, .awake);
        const result = try @call(.auto, work, args);
        std.mem.doNotOptimizeAway(result);
        const elapsed: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).toNanoseconds());
        best = @min(best, elapsed);
    }
    return best;
}

fn allocateEachPass(gpa: Allocator, values: []const u64) !u64 {
    var total: u64 = 0;
    for (values) |value| {
        const scratch = try gpa.alloc(u64, 16);
        defer gpa.free(scratch);
        @memset(scratch, value);
        total +%= scratch[value % 16];
    }
    return total;
}

fn allocateOnce(gpa: Allocator, values: []const u64) !u64 {
    const scratch = try gpa.alloc(u64, 16);
    defer gpa.free(scratch);
    var total: u64 = 0;
    for (values) |value| {
        @memset(scratch, value);
        total +%= scratch[value % 16];
    }
    return total;
}

fn trimEachPass(lines: []const []const u8, word: []const u8) !usize {
    var found: usize = 0;
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, std.mem.trim(u8, word, " ")) != null) found += 1;
    }
    return found;
}

fn trimOnce(lines: []const []const u8, word: []const u8) !usize {
    const wanted = std.mem.trim(u8, word, " ");
    var found: usize = 0;
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, wanted) != null) found += 1;
    }
    return found;
}

const Node = struct { id: u64, weight: u64 };

fn sumBoxed(nodes: []*Node) !u64 {
    var total: u64 = 0;
    for (nodes) |node| total +%= node.weight;
    return total;
}

fn sumFlat(nodes: []Node) !u64 {
    var total: u64 = 0;
    for (nodes) |node| total +%= node.weight;
    return total;
}

const Padded = extern struct { ready: bool, count: u64, small: bool };
const Ordered = extern struct { count: u64, ready: bool, small: bool };

fn sumPadded(items: []const Padded) !u64 {
    var total: u64 = 0;
    for (items) |item| total +%= item.count + @intFromBool(item.ready);
    return total;
}

fn sumOrdered(items: []const Ordered) !u64 {
    var total: u64 = 0;
    for (items) |item| total +%= item.count + @intFromBool(item.ready);
    return total;
}

const Wide = struct { id: u64, name: [32]u8, created: i64, updated: i64, owner: u64, region: u32, flags: u32, tags: [4]u64, balance: f64, limit: f64, currency: [4]u8 };

fn sumWide(accounts: []const Wide) !f64 {
    var total: f64 = 0;
    for (accounts) |account| total += account.balance;
    return total;
}

fn sumBalances(balances: []const f64) !f64 {
    var total: f64 = 0;
    for (balances) |balance| total += balance;
    return total;
}
