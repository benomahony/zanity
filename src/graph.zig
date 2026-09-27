const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Function = facts_module.Function;
const Edge = facts_module.Edge;
const Finding = facts_module.Finding;

pub const Cycle = struct { members: []const u32 };

const unvisited = std.math.maxInt(u32);

const Frame = struct { node: u32, next_edge: u32 };

pub const CycleScratch = struct {
    by_name: memory.Bounded(u32),
    offsets: memory.Bounded(u32),
    targets: memory.Bounded(u32),
    index: []u32,
    low: []u32,
    on_stack: []bool,
    stack: memory.Bounded(u32),
    frames: memory.Bounded(Frame),
    members: memory.Bounded(u32),
    cycles: memory.Bounded(Cycle),

    pub fn initGraphScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!CycleScratch {
        assert(limits.functions > 0);
        assert(limits.edges > 0);
        return .{
            .by_name = try .initBounded(gpa, limits.functions, "functions across all files"),
            .offsets = try .initBounded(gpa, limits.functions + 1, "functions across all files"),
            .targets = try .initBounded(gpa, limits.edges, "call edges across all files"),
            .index = try gpa.alloc(u32, limits.functions),
            .low = try gpa.alloc(u32, limits.functions),
            .on_stack = try gpa.alloc(bool, limits.functions),
            .stack = try .initBounded(gpa, limits.functions, "functions on the cycle search stack"),
            .frames = try .initBounded(gpa, limits.functions, "nested calls in the cycle search"),
            .members = try .initBounded(gpa, limits.functions, "functions in call cycles"),
            .cycles = try .initBounded(gpa, limits.functions, "call cycles"),
        };
    }
};

/// Call graph in compressed sparse row form: the callees of `v` are
/// `targets[offsets[v]..offsets[v + 1]]`.
pub const Graph = struct {
    offsets: []const u32,
    targets: []const u32,

    pub fn fromFacts(s: *CycleScratch, facts: *const Facts) error{LimitExceeded}!Graph {
        const functions = facts.functions.items();
        assert(functions.len < unvisited);
        s.by_name.clear();
        for (0..functions.len) |i| try s.by_name.add(@intCast(i));
        std.mem.sort(u32, s.by_name.items(), functions, nameOrder);
        s.offsets.clear();
        for (0..functions.len + 1) |_| try s.offsets.add(0);
        const offsets = s.offsets.items();
        for (facts.calls.items()) |call| {
            const lookup: Lookup = .{ .functions = functions, .sorted = s.by_name.items(), .call = call };
            for (lookup.candidates()) |c| {
                if (lookup.accepts(c)) offsets[call.caller + 1] += 1;
            }
        }
        for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
        s.targets.clear();
        for (0..offsets[functions.len]) |_| try s.targets.add(0);
        const cursor = s.low[0..functions.len];
        @memcpy(cursor, offsets[0..functions.len]);
        for (facts.calls.items()) |call| {
            const lookup: Lookup = .{ .functions = functions, .sorted = s.by_name.items(), .call = call };
            for (lookup.candidates()) |c| {
                if (!lookup.accepts(c)) continue;
                s.targets.items()[cursor[call.caller]] = c;
                cursor[call.caller] += 1;
            }
        }
        assert(offsets.len == functions.len + 1);
        assert(s.targets.len == offsets[functions.len]);
        return .{ .offsets = offsets, .targets = s.targets.items() };
    }

    fn out(self: Graph, v: u32) []const u32 {
        assert(v + 1 < self.offsets.len);
        assert(self.offsets[v] <= self.offsets[v + 1]);
        return self.targets[self.offsets[v]..self.offsets[v + 1]];
    }

    pub fn cycles(self: Graph, s: *CycleScratch) error{LimitExceeded}![]const Cycle {
        const n = self.offsets.len - 1;
        assert(n < unvisited);
        assert(n <= s.index.len);
        const index = s.index[0..n];
        const low = s.low[0..n];
        @memset(index, unvisited);
        @memset(s.on_stack[0..n], false);
        s.frames.clear();
        s.stack.clear();
        s.members.clear();
        s.cycles.clear();
        var counter: u32 = 0;
        for (0..n) |root| {
            if (index[root] != unvisited) continue;
            try s.frames.add(.{ .node = @intCast(root), .next_edge = 0 });
            for (0..2 * (n + self.targets.len) + 1) |_| {
                const frame = s.frames.last() orelse break;
                const v = frame.node;
                if (frame.next_edge == 0 and index[v] == unvisited) {
                    index[v] = counter;
                    low[v] = counter;
                    counter += 1;
                    try s.stack.add(v);
                    s.on_stack[v] = true;
                }
                const callees = self.out(v);
                if (frame.next_edge < callees.len) {
                    const w = callees[frame.next_edge];
                    frame.next_edge += 1;
                    if (index[w] == unvisited) {
                        try s.frames.add(.{ .node = w, .next_edge = 0 });
                    } else if (s.on_stack[w]) {
                        low[v] = @min(low[v], index[w]);
                    }
                    continue;
                }
                _ = s.frames.drop();
                if (s.frames.last()) |parent| low[parent.node] = @min(low[parent.node], low[v]);
                if (low[v] == index[v]) try self.component(s, v);
            }
            assert(s.frames.len == 0);
        }
        assert(s.stack.len == 0);
        return s.cycles.items();
    }

    fn component(self: Graph, s: *CycleScratch, root: u32) error{LimitExceeded}!void {
        const start = s.members.len;
        for (0..s.stack.len) |_| {
            const w = s.stack.drop().?;
            s.on_stack[w] = false;
            try s.members.add(w);
            if (w == root) break;
        }
        const members = s.members.items()[start..];
        assert(members.len > 0);
        assert(members[members.len - 1] == root);
        const cyclic = members.len > 1 or std.mem.indexOfScalar(u32, self.out(root), root) != null;
        if (cyclic) try s.cycles.add(.{ .members = members }) else s.members.len = start;
    }
};

const Lookup = struct {
    functions: []const Function,
    sorted: []const u32,
    call: Edge,

    fn candidates(self: Lookup) []const u32 {
        const lo = std.sort.lowerBound(u32, self.sorted, self, compareName);
        var hi = lo;
        while (hi < self.sorted.len and std.mem.eql(u8, self.functions[self.sorted[hi]].name, self.call.callee)) hi += 1;
        assert(lo <= hi);
        assert(hi <= self.sorted.len);
        return self.sorted[lo..hi];
    }

    /// A call resolves to same-file candidates when there are any, and only
    /// to functions or methods when the call syntax says which it must be.
    fn accepts(self: Lookup, c: u32) bool {
        const caller_path = self.functions[self.call.caller].path;
        assert(c < self.functions.len);
        if (!reaches(self.call.reach, self.functions[c].method)) return false;
        if (std.mem.eql(u8, self.functions[c].path, caller_path)) return true;
        for (self.candidates()) |other| {
            const local = std.mem.eql(u8, self.functions[other].path, caller_path);
            if (local and reaches(self.call.reach, self.functions[other].method)) return false;
        }
        assert(self.call.callee.len > 0);
        return true;
    }
};

fn compareName(lookup: Lookup, id: u32) std.math.Order {
    assert(id < lookup.functions.len);
    assert(lookup.call.callee.len > 0);
    return std.mem.order(u8, lookup.call.callee, lookup.functions[id].name);
}

fn nameOrder(functions: []const Function, a: u32, b: u32) bool {
    assert(a < functions.len);
    assert(b < functions.len);
    const by_name = std.mem.order(u8, functions[a].name, functions[b].name);
    return if (by_name == .eq) a < b else by_name == .lt;
}

fn reaches(reach: facts_module.Reach, method: bool) bool {
    const result = switch (reach) {
        .any => true,
        .functions => !method,
        .methods => method,
    };
    assert(result or reach != .any);
    assert(!result or reach != .methods or method);
    return result;
}

pub fn recursion(s: *CycleScratch, facts: *const Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const graph = try Graph.fromFacts(s, facts);
    const before = findings.len;
    for (try graph.cycles(s)) |cycle| {
        for (cycle.members) |member| {
            const f = facts.functions.items()[member];
            const message = if (cycle.members.len == 1)
                try facts.text.format("'{s}' calls itself, so how deep it goes depends on its input.", .{f.name})
            else
                try facts.text.format("'{s}' is part of a cycle of {d} functions that call each other, so how deep it goes depends on its input.", .{ f.name, cycle.members.len });
            try findings.add(.{ .path = f.path, .line = f.line, .column = f.column, .rule = "recursion", .message = message });
        }
    }
    assert(findings.len - before <= facts.functions.len);
    assert(graph.offsets.len == facts.functions.len + 1);
}

test "cycles are found without recursion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var s = try CycleScratch.initGraphScratch(arena_state.allocator(), .{ .functions = 8, .edges = 8 });
    const graph: Graph = .{ .offsets = &.{ 0, 1, 2, 3, 4 }, .targets = &.{ 1, 0, 2, 0 } };
    var members: usize = 0;
    const found = try graph.cycles(&s);
    for (found) |c| members += c.members.len;
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(usize, 3), members);
}
