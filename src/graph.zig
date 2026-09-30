const std = @import("std");
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
        if (limits.functions == 0) std.debug.panic("memory.Limits.functions is 0, so the call graph has no room for any function", .{});
        if (limits.edges == 0) std.debug.panic("memory.Limits.edges is 0, so the call graph has no room for any call", .{});
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
        if (functions.len >= unvisited) std.debug.panic("{d} functions reach the 'unvisited' marker {d}; lower memory.Limits.functions", .{ functions.len, unvisited });
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
        if (offsets.len != functions.len + 1) std.debug.panic("the call graph has {d} row offsets for {d} functions; it needs one more than the functions", .{ offsets.len, functions.len });
        if (s.targets.len != offsets[functions.len]) std.debug.panic("the call graph stores {d} call targets but its last offset says {d}", .{ s.targets.len, offsets[functions.len] });
        return .{ .offsets = offsets, .targets = s.targets.items() };
    }

    fn out(self: Graph, v: u32) []const u32 {
        if (v + 1 >= self.offsets.len) std.debug.panic("asked for the calls of function {d}, but the graph has {d} functions; pass an index below the function count from the facts", .{ v, self.offsets.len -| 1 });
        if (self.offsets[v] > self.offsets[v + 1]) std.debug.panic("function {d}'s calls run backwards ({d}..{d}); the offsets were not built in order, so build() must fill the offsets in function order", .{ v, self.offsets[v], self.offsets[v + 1] });
        return self.targets[self.offsets[v]..self.offsets[v + 1]];
    }

    pub fn cycles(self: Graph, s: *CycleScratch) error{LimitExceeded}![]const Cycle {
        const n = self.offsets.len - 1;
        if (n >= unvisited) std.debug.panic("{d} functions reach the 'unvisited' marker {d}; lower memory.Limits.functions", .{ n, unvisited });
        if (n > s.index.len) std.debug.panic("the graph has {d} functions but the cycle search has room for {d}; memory.Limits.functions is too low", .{ n, s.index.len });
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
            if (s.frames.len != 0) std.debug.panic("the cycle search from function {d} ended with {d} frames still open", .{ root, s.frames.len });
        }
        if (s.stack.len != 0) std.debug.panic("the cycle search ended with {d} functions still on its stack; a component was not popped", .{s.stack.len});
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
        if (members.len == 0) std.debug.panic("function {d} closed a component with no members; it was not on the stack", .{root});
        if (members[members.len - 1] != root) std.debug.panic("function {d}'s component ends with function {d}; the stack was not popped down to its root", .{ root, members[members.len - 1] });
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
        if (lo > hi) std.debug.panic("the functions named '{s}' run backwards ({d}..{d}); build() must sort the names before candidates() searches them", .{ self.call.callee, lo, hi });
        if (hi > self.sorted.len) std.debug.panic("the functions named '{s}' end at {d}, past the {d} sorted names; candidates() must bound its run by the sorted names, so check its search", .{ self.call.callee, hi, self.sorted.len });
        return self.sorted[lo..hi];
    }

    /// A call resolves to same-file candidates when there are any, and only
    /// to functions or methods when the call syntax says which it must be.
    fn accepts(self: Lookup, c: u32) bool {
        const caller_path = self.functions[self.call.caller].path;
        if (c >= self.functions.len) std.debug.panic("call to '{s}' resolved to function {d}, but only {d} are recorded", .{ self.call.callee, c, self.functions.len });
        if (!reaches(self.call.reach, self.functions[c].method)) return false;
        if (std.mem.eql(u8, self.functions[c].path, caller_path)) return true;
        for (self.candidates()) |other| {
            const local = std.mem.eql(u8, self.functions[other].path, caller_path);
            if (local and reaches(self.call.reach, self.functions[other].method)) return false;
        }
        if (self.call.callee.len == 0) std.debug.panic("function {d} calls something with an empty name; check the @call.name capture", .{self.call.caller});
        return true;
    }
};

fn compareName(lookup: Lookup, id: u32) std.math.Order {
    if (id >= lookup.functions.len) std.debug.panic("looking up '{s}' reached function {d}, but only {d} are recorded", .{ lookup.call.callee, id, lookup.functions.len });
    if (lookup.call.callee.len == 0) std.debug.panic("function {d} calls something with an empty name; check the @call.name capture", .{lookup.call.caller});
    return std.mem.order(u8, lookup.call.callee, lookup.functions[id].name);
}

fn nameOrder(functions: []const Function, a: u32, b: u32) bool {
    if (a >= functions.len) std.debug.panic("sorting function {d}, but only {d} are recorded", .{ a, functions.len });
    if (b >= functions.len) std.debug.panic("sorting function {d}, but only {d} are recorded", .{ b, functions.len });
    const by_name = std.mem.order(u8, functions[a].name, functions[b].name);
    return if (by_name == .eq) a < b else by_name == .lt;
}

fn reaches(reach: facts_module.Reach, method: bool) bool {
    const result = switch (reach) {
        .any => true,
        .functions => !method,
        .methods => method,
    };
    if (!result and reach == .any) std.debug.panic("a call that can reach anything ({t}) refused a {s}; reaches() must return true for .any, so check its switch", .{ reach, if (method) "method" else "function" });
    if (result and reach == .methods and !method) std.debug.panic("a call that can only reach methods accepted a plain function; reaches() must refuse plain functions for .methods, so check its switch", .{});
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
    if (findings.len - before > facts.functions.len) std.debug.panic("recursion reported {d} findings for {d} functions; each function can be in at most one cycle, so recursion() must mark each function it reports and skip it after", .{ findings.len - before, facts.functions.len });
    if (graph.offsets.len != facts.functions.len + 1) std.debug.panic("the call graph has {d} row offsets for {d} functions; build() must write one offset per function plus one", .{ graph.offsets.len, facts.functions.len });
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
