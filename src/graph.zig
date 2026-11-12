//! The project-wide call graph built from every file's facts, and the checks that need it, such as
//! finding recursion through cycles. Lookups are by name, so it runs after all files are read. The
//! cycle search works on any graph in the same form, such as the files that import each other.
const std = @import("std");
const assert = @import("assert.zig");
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

/// What the cycle search knows of each node of a graph, and the cycles it has found.
pub const CycleSearch = struct {
    index: []u32,
    low: []u32,
    on_stack: []bool,
    stack: memory.Bounded(u32),
    frames: memory.Bounded(Frame),
    members: memory.Bounded(u32),
    cycles: memory.Bounded(Cycle),

    /// Room to search a graph of up to `nodes` nodes, which a limit names as `noun`.
    pub fn initCycleSearch(gpa: Allocator, nodes: u32, comptime noun: []const u8) Allocator.Error!CycleSearch {
        if (nodes == 0) assert.panic("searching for cycles among no " ++ noun ++ "; memory.Limits must allow at least one", .{});
        const search: CycleSearch = .{
            .index = try memory.reserveUninitialized(gpa, u32, nodes),
            .low = try memory.reserveUninitialized(gpa, u32, nodes),
            .on_stack = try memory.reserveUninitialized(gpa, bool, nodes),
            .stack = try .initBounded(gpa, nodes, noun ++ " on the cycle search stack"),
            .frames = try .initBounded(gpa, nodes, noun ++ " open in the cycle search"),
            .members = try .initBounded(gpa, nodes, noun ++ " in cycles"),
            .cycles = try .initBounded(gpa, nodes, "cycles among " ++ noun),
        };
        if (search.low.len != search.index.len) assert.panic("reserved {d} low links for {d} nodes", .{ search.low.len, search.index.len });
        return search;
    }
};

pub const CycleScratch = struct {
    by_name: memory.Bounded(u32),
    offsets: memory.Bounded(u32),
    targets: memory.Bounded(u32),
    search: CycleSearch,

    pub fn initGraphScratch(gpa: Allocator, limits: memory.Limits) Allocator.Error!CycleScratch {
        if (limits.functions == 0) assert.panic("memory.Limits.functions is 0, so the call graph has no room for any function", .{});
        if (limits.edges == 0) assert.panic("memory.Limits.edges is 0, so the call graph has no room for any call", .{});
        return .{
            .by_name = try .initBounded(gpa, limits.functions, "functions across all files"),
            .offsets = try .initBounded(gpa, std.math.add(usize, limits.functions, 1) catch return error.OutOfMemory, "functions across all files"),
            .targets = try .initBounded(gpa, limits.edges, "call edges across all files"),
            .search = try .initCycleSearch(gpa, limits.functions, "functions"),
        };
    }
};

/// A graph in compressed sparse row form, such as the call graph: the nodes `v` leads to are
/// `targets[offsets[v]..offsets[v + 1]]`.
pub const Graph = struct {
    offsets: []const u32,
    targets: []const u32,

    pub fn fromFacts(s: *CycleScratch, facts: *const Facts) error{LimitExceeded}!Graph {
        const functions = facts.functions.items();
        if (functions.len >= unvisited) assert.panic("{d} functions reach the 'unvisited' marker {d}; lower memory.Limits.functions", .{ functions.len, unvisited });
        s.by_name.clear();
        for (0..functions.len) |i| try s.by_name.add(@intCast(i));
        const sorted = s.by_name.items();
        std.mem.sort(u32, sorted, functions, nameOrder);
        s.offsets.clear();
        for (0..functions.len + 1) |_| try s.offsets.add(0);
        const offsets = s.offsets.items();
        s.targets.clear();
        for (facts.calls.items()) |call| {
            const lookup: Lookup = .{ .functions = functions, .sorted = sorted, .call = call };
            for (lookup.candidates()) |c| {
                if (!lookup.accepts(c)) continue;
                try s.targets.add(0);
                offsets[call.caller + 1] += 1;
            }
        }
        for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
        const cursor = s.search.low[0..functions.len];
        @memcpy(cursor, offsets[0..functions.len]);
        for (facts.calls.items()) |call| {
            const lookup: Lookup = .{ .functions = functions, .sorted = sorted, .call = call };
            for (lookup.candidates()) |c| {
                if (!lookup.accepts(c)) continue;
                s.targets.items()[cursor[call.caller]] = c;
                cursor[call.caller] += 1;
            }
        }
        if (offsets.len != functions.len + 1) assert.panic("the call graph has {d} row offsets for {d} functions; it needs one more than the functions", .{ offsets.len, functions.len });
        if (s.targets.len != offsets[functions.len]) assert.panic("the call graph stores {d} call targets but its last offset says {d}; fromFacts() must write every target it counts", .{ s.targets.len, offsets[functions.len] });
        return .{ .offsets = offsets, .targets = s.targets.items() };
    }

    fn out(self: Graph, v: u32) []const u32 {
        if (v >= self.offsets.len -| 1) assert.panic("asked for the edges of node {d}, but the graph has {d} nodes; pass an index below the node count", .{ v, self.offsets.len -| 1 });
        if (self.offsets[v] > self.offsets[v + 1]) assert.panic("node {d}'s edges run backwards ({d}..{d}); the offsets were not built in order, so fill them in node order", .{ v, self.offsets[v], self.offsets[v + 1] });
        return self.targets[self.offsets[v]..self.offsets[v + 1]];
    }

    pub fn cycles(self: Graph, s: *CycleSearch) error{LimitExceeded}![]const Cycle {
        const n = self.offsets.len - 1;
        if (n >= unvisited) assert.panic("{d} nodes reach the 'unvisited' marker {d}; lower the memory.Limits the graph is built under", .{ n, unvisited });
        if (n > s.index.len) assert.panic("the graph has {d} nodes but the cycle search has room for {d}; reserve the search from the same memory.Limits as the graph", .{ n, s.index.len });
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
            if (s.frames.len != 0) assert.panic("the cycle search from node {d} ended with {d} frames still open; the cycle search must pop every frame it pushes, so check its exits", .{ root, s.frames.len });
        }
        if (s.stack.len != 0) assert.panic("the cycle search ended with {d} nodes still on its stack; a component was not popped", .{s.stack.len});
        return s.cycles.items();
    }

    fn component(self: Graph, s: *CycleSearch, root: u32) error{LimitExceeded}!void {
        const start = s.members.len;
        for (0..s.stack.len) |_| {
            const w = s.stack.drop().?;
            s.on_stack[w] = false;
            try s.members.add(w);
            if (w == root) break;
        }
        const members = s.members.items()[start..];
        if (members.len == 0) assert.panic("node {d} closed a component with no members; it was not on the stack, so check that cycles() pushes a node before component() closes it", .{root});
        if (members[members.len - 1] != root) assert.panic("node {d}'s component ends with node {d}; the stack was not popped down to its root, so check the popping loop in component()", .{ root, members[members.len - 1] });
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
        if (lo > hi) assert.panic("the functions named '{s}' run backwards ({d}..{d}); build() must sort the names before candidates() searches them", .{ self.call.callee, lo, hi });
        if (hi > self.sorted.len) assert.panic("the functions named '{s}' end at {d}, past the {d} sorted names; candidates() must bound its run by the sorted names, so check its search", .{ self.call.callee, hi, self.sorted.len });
        return self.sorted[lo..hi];
    }

    /// A call resolves as `placed` does, and among those candidates only to the ones that fit it
    /// best: that take as many parameters as it passes arguments, so `Emit(event)` inside the
    /// five-parameter overload `Emit` reaches the one-parameter `Emit`, not itself; and of those,
    /// the ones whose parameter types its arguments plainly have, so `Sign("text")` reaches
    /// `Sign(string)` and not `Sign(byte[])`. When none fit, as with default arguments, Python's
    /// `self` or an argument of a subtype, it reaches them all.
    fn accepts(self: Lookup, c: u32) bool {
        if (c >= self.functions.len) assert.panic("call to '{s}' resolved to function {d}, but only {d} are recorded; resolve calls only against the recorded functions", .{ self.call.callee, c, self.functions.len });
        if (!self.placed(c)) return false;
        const own = self.fit(c);
        for (self.candidates()) |other| {
            if (other != c and self.fit(other) > own and self.placed(other)) return false;
        }
        if (own > 2) assert.panic("function {d} fits the call to '{s}' at level {d}; fit() has levels 0 to 2", .{ c, self.call.callee, own });
        return true;
    }

    /// How well function `c` fits the call: 0 when it takes another number of parameters, 1 when
    /// it takes as many as the call passes arguments, 2 when their types agree as well.
    fn fit(self: Lookup, c: u32) u2 {
        if (c >= self.functions.len) assert.panic("fitting function {d} to the call to '{s}', but only {d} are recorded; fit only candidates()", .{ c, self.call.callee, self.functions.len });
        const function = self.functions[c];
        if (!std.mem.eql(u8, function.name, self.call.callee)) assert.panic("fitting '{s}' to a call to '{s}'; fit only candidates(), which share the call's name", .{ function.name, self.call.callee });
        if (function.parameters != self.call.arguments) return 0;
        return if (facts_module.typesAgree(self.call.types, function.types)) 2 else 1;
    }

    /// A call resolves to same-file candidates when there are any, and only
    /// to functions or methods when the call syntax says which it must be.
    fn placed(self: Lookup, c: u32) bool {
        const caller_path = self.functions[self.call.caller].path;
        if (c >= self.functions.len) assert.panic("call to '{s}' resolved to function {d}, but only {d} are recorded; resolve calls only against the recorded functions", .{ self.call.callee, c, self.functions.len });
        if (!reaches(self.call.reach, self.functions[c].method)) return false;
        if (std.mem.eql(u8, self.functions[c].path, caller_path)) return true;
        for (self.candidates()) |other| {
            const local = std.mem.eql(u8, self.functions[other].path, caller_path);
            if (local and reaches(self.call.reach, self.functions[other].method)) return false;
        }
        if (self.call.callee.len == 0) assert.panic("function {d} calls something with an empty name; check the @call.name capture", .{self.call.caller});
        return true;
    }
};

fn compareName(lookup: Lookup, id: u32) std.math.Order {
    if (id >= lookup.functions.len) assert.panic("looking up '{s}' reached function {d}, but only {d} are recorded; compareName() must index only the recorded functions", .{ lookup.call.callee, id, lookup.functions.len });
    const callee = lookup.call.callee;
    if (callee.len == 0) assert.panic("function {d} calls something with an empty name; check the @call.name capture", .{lookup.call.caller});
    return std.mem.order(u8, lookup.call.callee, lookup.functions[id].name);
}

fn nameOrder(functions: []const Function, a: u32, b: u32) bool {
    if (a >= functions.len) assert.panic("sorting function {d}, but only {d} are recorded; sort only indices of recorded functions", .{ a, functions.len });
    if (b >= functions.len) assert.panic("sorting function {d}, but only {d} are recorded; sort only indices of recorded functions", .{ b, functions.len });
    const by_name = std.mem.order(u8, functions[a].name, functions[b].name);
    return if (by_name == .eq) a < b else by_name == .lt;
}

fn reaches(reach: facts_module.Reach, method: bool) bool {
    const result = switch (reach) {
        .any => true,
        .functions => !method,
        .methods => method,
    };
    if (!result and reach == .any) assert.panic("a call that can reach anything ({t}) refused a {s}; reaches() must return true for .any, so check its switch", .{ reach, if (method) "method" else "function" });
    if (result and reach == .methods and !method) assert.panic("a call that can only reach methods accepted a plain function; reaches() must refuse plain functions for .methods, so check its switch", .{});
    return result;
}

pub fn recursion(s: *CycleScratch, facts: *const Facts, findings: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const graph = try Graph.fromFacts(s, facts);
    const before = findings.len;
    for (try graph.cycles(&s.search)) |cycle| {
        for (cycle.members) |member| {
            const f = facts.functions.items()[member];
            const message = if (cycle.members.len == 1)
                try facts.text.format("'{s}' calls itself, so how deep it goes depends on its input.", .{f.name})
            else
                try facts.text.format("'{s}' is part of a cycle of {d} functions that call each other, so how deep it goes depends on its input.", .{ f.name, cycle.members.len });
            try findings.add(.{ .path = f.path, .line = f.line, .column = f.column, .rule = "recursion", .message = message });
        }
    }
    if (findings.len - before > facts.functions.len) assert.panic("recursion reported {d} findings for {d} functions; each function can be in at most one cycle, so recursion() must mark each function it reports and skip it after", .{ findings.len - before, facts.functions.len });
    if (graph.offsets.len != facts.functions.len + 1) assert.panic("the call graph has {d} row offsets for {d} functions; build() must write one offset per function plus one", .{ graph.offsets.len, facts.functions.len });
}

test "cycles are found without recursion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var s = try CycleScratch.initGraphScratch(arena_state.allocator(), .{ .functions = 8, .edges = 8 });
    const graph: Graph = .{ .offsets = &.{ 0, 1, 2, 3, 4 }, .targets = &.{ 1, 0, 2, 0 } };
    var members: usize = 0;
    const found = try graph.cycles(&s.search);
    for (found) |c| members += c.members.len;
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(usize, 3), members);
}

test "a call reaches the overload whose parameters fit its arguments, or every overload when none do" {
    const functions = [_]Function{
        .{ .path = "a.cs", .name = "Emit", .method = true, .line = 1, .column = 1, .parameters = 1 },
        .{ .path = "a.cs", .name = "Emit", .method = true, .line = 9, .column = 1, .parameters = 5 },
    };
    const sorted = [_]u32{ 0, 1 };
    const fitting: Lookup = .{ .functions = &functions, .sorted = &sorted, .call = .{ .caller = 1, .callee = "Emit", .reach = .any, .arguments = 1 } };
    try std.testing.expectEqual(true, fitting.accepts(0));
    try std.testing.expectEqual(false, fitting.accepts(1));
    const unfitting: Lookup = .{ .functions = &functions, .sorted = &sorted, .call = .{ .caller = 1, .callee = "Emit", .reach = .any, .arguments = 3 } };
    try std.testing.expectEqual(true, unfitting.accepts(0));
    try std.testing.expectEqual(true, unfitting.accepts(1));
}

test "among overloads that fit its arguments, a call reaches the ones whose types they plainly have" {
    const functions = [_]Function{
        .{ .path = "a.cs", .name = "Sign", .method = true, .line = 1, .column = 1, .parameters = 1, .types = "string" },
        .{ .path = "a.cs", .name = "Sign", .method = true, .line = 9, .column = 1, .parameters = 1, .types = "byte[]" },
    };
    const sorted = [_]u32{ 0, 1 };
    const text: Lookup = .{ .functions = &functions, .sorted = &sorted, .call = .{ .caller = 1, .callee = "Sign", .reach = .any, .arguments = 1, .types = "string" } };
    try std.testing.expectEqual(true, text.accepts(0));
    try std.testing.expectEqual(false, text.accepts(1));
    const unknown: Lookup = .{ .functions = &functions, .sorted = &sorted, .call = .{ .caller = 1, .callee = "Sign", .reach = .any, .arguments = 1 } };
    try std.testing.expectEqual(true, unknown.accepts(0));
    try std.testing.expectEqual(true, unknown.accepts(1));
}

test "overload expansion respects the edge limit before accumulating offsets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var text = try memory.Text.initText(gpa, 1024);
    var facts = try Facts.initFacts(gpa, .{ .definitions = 4, .functions = 4, .calls = 4, .references = 4 }, &text);
    try facts.functions.add(.{ .path = "a.cs", .name = "Emit", .method = true, .line = 1, .column = 1, .parameters = 1 });
    try facts.functions.add(.{ .path = "a.cs", .name = "Emit", .method = true, .line = 2, .column = 1, .parameters = 2 });
    try facts.calls.add(.{ .caller = 0, .callee = "Emit", .reach = .any, .arguments = 3 });
    var scratch = try CycleScratch.initGraphScratch(gpa, .{ .functions = 4, .edges = 1 });
    try std.testing.expectError(error.LimitExceeded, Graph.fromFacts(&scratch, &facts));
    try std.testing.expectEqualStrings("call edges across all files", memory.exceeded);
}
