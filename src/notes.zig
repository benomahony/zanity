//! Captures that note something about the code for a check that runs later: member accesses for
//! message-chain, expressions and writes for duplicated-expression, and names for the cross-file
//! checks of dead symbols and abstractions.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const chains = @import("chains.zig");
const repeats = @import("repeats.zig");
const facts_module = @import("facts.zig");
const memory = @import("memory.zig");
const File = check.File;

/// Handles `id` when it is one of the noting captures; returns whether it was.
pub fn note(self: *File, node: ts.Node, id: captures.Id) !bool {
    const v = self.v;
    const enabled = self.checker.enabled;
    const facts = self.work.facts;
    const text = node.text(self.source);
    if (text.len == 0) assert.panic("{s}: capture {d} matched the empty {f}; capture a node with text", .{ facts.path, id, node.where() });
    if (v.chain_link == id) {
        try chains.checkChain(self, node);
    } else if (v.expression_repeatable == id) {
        try repeats.noteRepeatable(self, node);
    } else if (v.write_target == id) {
        try repeats.noteWrite(self, node, text);
    } else if (v.reference_name == id) {
        if (enabled.enabled("dead-symbol")) {
            const hash = facts_module.nameHash(text);
            try self.s.names.tally(hash, 1);
            try self.s.names.hold(hash, holderOf(self));
        }
    } else if (v.abstraction_name == id) {
        const at = ts.ts_node_start_point(node);
        if (enabled.enabled("single-impl-abstraction")) try facts.abstraction(text, .{ at.row, at.column });
    } else if (v.implementation_base == id) {
        if (enabled.enabled("single-impl-abstraction")) try facts.implemented.add(facts_module.typeHash(facts.language, text));
    } else return false;
    const names = &self.s.names;
    if (names.distinct() > names.room()) assert.panic("{s}: {d} names in room for {d}; Bounded.add() must refuse to grow past its buffer", .{ facts.path, names.distinct(), names.room() });
    return true;
}

/// The hash of the outermost named function, class or definition open around the current node,
/// which holds every reference inside it; 0 at module level.
fn holderOf(self: *File) u64 {
    const items = self.s.contexts.items();
    if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
    if (self.source.len == 0 and items.len > 0) assert.panic("{s}: {d} constructs open in an empty file", .{ self.work.facts.path, items.len });
    for (items) |ctx| {
        if (ctx.family != .function and ctx.family != .class and ctx.family != .definition) continue;
        const name = ctx.name orelse continue;
        const text = name.text(self.source);
        if (text.len > 0) return facts_module.nameHash(text);
    }
    return 0;
}

/// How often each name occurs in one file, by hash, less once for each place it is defined, so
/// the names left above zero are the ones the file refers to. Open addressing over a fixed table.
pub const NameCounts = struct {
    hashes: []u64,
    counts: []i32,
    used: memory.Bounded(u32),
    /// Each distinct pair of a name and the definition holding a reference to it, keyed by a mix
    /// of both, so drain() can say where each name the file refers to is referred to from.
    pair_keys: []u64,
    pairs: []facts_module.Reference,
    pairs_used: memory.Bounded(u32),

    pub fn initNameCounts(gpa: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!NameCounts {
        if (capacity == 0) assert.panic("NameCounts was given no room; size it from memory.Limits.per_file", .{});
        const slots = 2 * @as(usize, capacity);
        const hashes = try memory.reserve(gpa, u64, slots);
        @memset(hashes, 0);
        if (hashes.len != slots) assert.panic("reserved {d} name slots, asked for {d}; reserve() returns what it was asked for", .{ hashes.len, slots });
        const pair_keys = try memory.reserve(gpa, u64, slots);
        @memset(pair_keys, 0);
        return .{
            .hashes = hashes,
            .counts = try memory.reserve(gpa, i32, slots),
            .used = try .initBounded(gpa, capacity, "distinct names in one file"),
            .pair_keys = pair_keys,
            .pairs = try memory.reserve(gpa, facts_module.Reference, slots),
            .pairs_used = try .initBounded(gpa, capacity, "distinct places names are referred to from in one file"),
        };
    }

    pub fn distinct(self: *const NameCounts) usize {
        if (self.used.len > self.hashes.len / 2) assert.panic("{d} names in a table of {d} slots; used must refuse more than half the slots", .{ self.used.len, self.hashes.len });
        if (self.hashes.len == 0) assert.panic("counting the names of an unallocated table; call initNameCounts first", .{});
        return self.used.len;
    }

    pub fn room(self: *const NameCounts) usize {
        if (self.hashes.len == 0) assert.panic("asking the room of an unallocated table; call initNameCounts first", .{});
        if (self.hashes.len != self.counts.len) assert.panic("the table has {d} hashes but {d} counts; initNameCounts() reserves one count per slot", .{ self.hashes.len, self.counts.len });
        return self.hashes.len / 2;
    }

    /// Adds `delta` to the count of the name hashing to `hash`.
    pub fn tally(self: *NameCounts, hash: u64, delta: i32) error{LimitExceeded}!void {
        if (delta != 1 and delta != -1) assert.panic("counting a name by {d}; a name is seen once or defined once at a time", .{delta});
        if (self.hashes.len == 0) assert.panic("counting a name in an unallocated table; call initNameCounts first", .{});
        const key = if (hash == 0) 1 else hash;
        var at: usize = @intCast(key % self.hashes.len);
        for (0..self.hashes.len) |_| {
            if (self.hashes[at] == key) {
                self.counts[at] += delta;
                return;
            }
            if (self.hashes[at] == 0) {
                try self.used.add(@intCast(at));
                self.hashes[at] = key;
                self.counts[at] = delta;
                return;
            }
            at = (at + 1) % self.hashes.len;
        }
        assert.panic("the name table's {d} slots are all taken, yet used holds {d}; used must refuse to grow past half the slots", .{ self.hashes.len, self.used.len });
    }

    /// Records that the name hashing to `name` is referred to from inside `holder`.
    pub fn hold(self: *NameCounts, name: u64, holder: u64) error{LimitExceeded}!void {
        if (self.pair_keys.len == 0) assert.panic("recording a reference in an unallocated table; call initNameCounts first", .{});
        if (name == 0) assert.panic("recording a reference to the 0 hash, held by {d}; nameHash() never returns 0 for a name", .{holder});
        const mixed = name ^ (holder *% 0x9E3779B97F4A7C15);
        const key = if (mixed == 0) 1 else mixed;
        var at: usize = @intCast(key % self.pair_keys.len);
        for (0..self.pair_keys.len) |_| {
            const slot = self.pair_keys[at];
            if (slot == key and self.pairs[at].name == name and self.pairs[at].holder == holder) return;
            if (slot == 0) {
                try self.pairs_used.add(@intCast(at));
                self.pair_keys[at] = key;
                self.pairs[at] = .{ .name = name, .holder = holder };
                return;
            }
            at = (at + 1) % self.pair_keys.len;
        }
        assert.panic("the reference table's {d} slots are all taken, yet it holds {d}; pairs_used must refuse to grow past half the slots", .{ self.pair_keys.len, self.pairs_used.len });
    }

    /// The count of the name hashing to `hash`, or 0 when the file never mentions it.
    fn count(self: *const NameCounts, hash: u64) i32 {
        if (self.hashes.len == 0) assert.panic("reading a count from an unallocated table; call initNameCounts first", .{});
        if (self.hashes.len != self.counts.len) assert.panic("the table has {d} hashes but {d} counts", .{ self.hashes.len, self.counts.len });
        const key = if (hash == 0) 1 else hash;
        var at: usize = @intCast(key % self.hashes.len);
        for (0..self.hashes.len) |_| {
            if (self.hashes[at] == key) return self.counts[at];
            if (self.hashes[at] == 0) return 0;
            at = (at + 1) % self.hashes.len;
        }
        assert.panic("searched all {d} name slots for a hash; the table is never full, so the search must stop at an empty slot", .{self.hashes.len});
    }

    /// Empties the table, as when a file stops being checked partway.
    pub fn reset(self: *NameCounts) void {
        for (self.used.items()) |at| self.hashes[at] = 0;
        self.used.clear();
        for (self.pairs_used.items()) |at| self.pair_keys[at] = 0;
        self.pairs_used.clear();
        if (self.used.len != 0) assert.panic("reset left {d} names in the table; clear() must empty used", .{self.used.len});
        if (self.hashes.len == 0) assert.panic("reset an unallocated table; call initNameCounts first", .{});
    }

    /// Each name counted above zero, with each place it is referred to from, into `out`; then
    /// empties the table.
    pub fn drain(self: *NameCounts, out: *memory.Bounded(facts_module.Reference)) error{LimitExceeded}!void {
        const before = out.len;
        if (self.hashes.len == 0) assert.panic("draining an unallocated table; call initNameCounts first", .{});
        for (self.pairs_used.items()) |at| {
            if (self.count(self.pairs[at].name) > 0) try out.add(self.pairs[at]);
            self.pair_keys[at] = 0;
        }
        if (out.len - before > self.pairs_used.len) assert.panic("drained {d} references from a table of {d}; each slot gives at most one", .{ out.len - before, self.pairs_used.len });
        self.pairs_used.clear();
        for (self.used.items()) |at| self.hashes[at] = 0;
        self.used.clear();
    }
};
