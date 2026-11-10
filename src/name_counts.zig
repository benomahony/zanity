//! How often each name occurs in one file, for dead-symbol's references and their holders.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const facts_module = @import("facts.zig");

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
    /// The names of the file's top-level definitions no other file can name, which drain()
    /// records under their file's hash.
    privates: memory.Bounded(u64),

    pub fn initNameCounts(gpa: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!NameCounts {
        if (capacity == 0) assert.panic("NameCounts was given no room; size it from memory.Limits.per_file", .{});
        const slots = 2 * @as(usize, capacity);
        const hashes = try memory.reserveUninitialized(gpa, u64, slots);
        @memset(hashes, 0);
        if (hashes.len != slots) assert.panic("reserved {d} name slots, asked for {d}; reserve() returns what it was asked for", .{ hashes.len, slots });
        const pair_keys = try memory.reserveUninitialized(gpa, u64, slots);
        @memset(pair_keys, 0);
        return .{
            .hashes = hashes,
            .counts = try memory.reserveUninitialized(gpa, i32, slots),
            .used = try .initBounded(gpa, capacity, "distinct names in one file"),
            .pair_keys = pair_keys,
            .pairs = try memory.reserveUninitialized(gpa, facts_module.Reference, slots),
            .pairs_used = try .initBounded(gpa, capacity, "distinct places names are referred to from in one file"),
            .privates = try .initBounded(gpa, capacity, "file-private definitions in one file"),
        };
    }

    /// Records that the name hashing to `hash` is defined at the top of the file, where only the
    /// file can name it.
    pub fn private(self: *NameCounts, hash: u64) error{LimitExceeded}!void {
        if (hash == 0) assert.panic("recording a file-private name with the 0 hash; nameHash() never returns 0 for a name", .{});
        const before = self.privates.len;
        try self.privates.add(hash);
        if (self.privates.len != before + 1) assert.panic("recorded a file-private name but holds {d}, from {d}; Bounded.add() adds one", .{ self.privates.len, before });
    }

    /// Whether the file refers to the name hashing to `hash` anywhere other than where it is defined.
    pub fn mentioned(self: *const NameCounts, hash: u64) bool {
        if (hash == 0) assert.panic("asking whether the file mentions the 0 hash; nameHash() never returns 0 for a name", .{});
        const seen = self.count(hash);
        if (seen < -@as(i32, @intCast(self.used.len + 1))) assert.panic("a name is counted {d}, below minus the {d} names in the table; each definition subtracts one", .{ seen, self.used.len });
        return seen > 0;
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
        self.privates.clear();
        if (self.used.len != 0) assert.panic("reset left {d} names in the table; clear() must empty used", .{self.used.len});
        if (self.hashes.len == 0) assert.panic("reset an unallocated table; call initNameCounts first", .{});
    }

    /// Each name counted above zero, with each place it is referred to from, into `out`; then
    /// empties the table. A file-private name, as a reference or a holder, is recorded under its
    /// hash in the file at `path`, and is kept alive from module level when the file `reflects`
    /// on all its declarations.
    pub fn drain(self: *NameCounts, out: *memory.Bounded(facts_module.Reference), path: []const u8, reflects: bool) error{LimitExceeded}!void {
        const before = out.len;
        if (self.hashes.len == 0) assert.panic("draining an unallocated table; call initNameCounts first", .{});
        if (path.len == 0 and self.privates.len > 0) assert.panic("draining {d} file-private names with no file to key them by; pass facts.path", .{self.privates.len});
        const privates = self.privates.items();
        std.mem.sort(u64, privates, {}, std.sort.asc(u64));
        for (self.pairs_used.items()) |at| {
            var pair = self.pairs[at];
            if (self.count(pair.name) > 0) {
                pair.name = localKey(privates, path, pair.name);
                if (pair.holder != 0) pair.holder = localKey(privates, path, pair.holder);
                try out.add(pair);
            }
            self.pair_keys[at] = 0;
        }
        if (out.len - before > self.pairs_used.len) assert.panic("drained {d} references from a table of {d}; each slot gives at most one", .{ out.len - before, self.pairs_used.len });
        if (reflects) for (privates) |hash| try out.add(.{ .name = localKey(privates, path, hash) });
        self.privates.clear();
        self.pairs_used.clear();
        for (self.used.items()) |at| self.hashes[at] = 0;
        self.used.clear();
    }
};

/// The hash a reference to `hash` is recorded under: the file's own, when `sorted` file-private
/// names hold it.
fn localKey(sorted: []const u64, path: []const u8, hash: u64) u64 {
    if (hash == 0) assert.panic("{s}: keying the 0 hash; only nonzero name hashes are referred to", .{path});
    if (sorted.len > 1 and sorted[0] > sorted[sorted.len - 1]) assert.panic("{s}: {d} file-private names are not sorted; drain() sorts them first", .{ path, sorted.len });
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle] < hash) low = middle + 1 else high = middle;
    }
    const found = low < sorted.len and sorted[low] == hash;
    return if (found) facts_module.localHash(path, hash) else hash;
}
