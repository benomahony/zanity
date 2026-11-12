//! What one file imports at its top level, noted while the walk visits its captures: each
//! import's module, the name it binds the module to, the names it imports explicitly, and the
//! members the file reads through a binding, so cyclic-import can tell how much each import is used.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const ts = @import("ts.zig");
const facts_module = @import("facts.zig");

/// Names a finding quotes from one import.
const max_shown = 3;

/// One top-level import statement, keyed by where it starts.
const Entry = struct {
    statement: u32,
    line: u32,
    column: u32,
    spec: ?ts.Node = null,
    /// The hash of the name the whole module is bound to, or 0 for none.
    binding: u64 = 0,
    named: u32 = 0,
    shown: [max_shown]?ts.Node = @splat(null),
};

/// A member read through a name, as `engine.Limit` reads `Limit` through `engine`.
const Use = struct {
    via: u64,
    used: u64,
    start: u32,
    end: u32,

    /// Whether `a` sorts before `b`: by the name read through, then the member read.
    fn before(_: void, a: Use, b: Use) bool {
        if (a.via == 0) assert.panic("ordering a use at byte {d} read through the 0 hash; nameHash() never returns 0", .{a.start});
        if (b.via == 0) assert.panic("ordering a use at byte {d} read through the 0 hash; nameHash() never returns 0", .{b.start});
        return a.key() < b.key();
    }

    /// The name read through, then the member read, as one number to order uses by.
    fn key(self: Use) u128 {
        if (self.via == 0) assert.panic("keying a use at byte {d} read through the 0 hash; nameHash() never returns 0", .{self.start});
        if (self.end <= self.start) assert.panic("keying a use spanning bytes {d}..{d}; noteUsed() records a member with text", .{ self.start, self.end });
        return @as(u128, self.via) << 64 | self.used;
    }
};

pub const ImportNotes = struct {
    entries: memory.Bounded(Entry),
    uses: memory.Bounded(Use),
    /// The object of the member access the walk just passed, until its member arrives.
    pending: ?ts.Node = null,

    pub fn initImportNotes(gpa: std.mem.Allocator, limits: memory.Limits) std.mem.Allocator.Error!ImportNotes {
        if (limits.per_file == 0) assert.panic("memory.Limits.per_file is 0, so no import could be noted; set it above 0", .{});
        const notes: ImportNotes = .{
            .entries = try .initBounded(gpa, limits.per_file, "top-level imports in one file"),
            .uses = try .initBounded(gpa, limits.per_file, "members read through a name in one file"),
        };
        if (notes.entries.len != 0) assert.panic("a new ImportNotes holds {d} imports; it starts empty", .{notes.entries.len});
        return notes;
    }

    pub fn clear(self: *ImportNotes) void {
        if (self.entries.capacity() == 0 or self.uses.capacity() == 0) assert.panic("clearing import notes with room for {d} imports and {d} uses; initImportNotes() reserves both", .{ self.entries.capacity(), self.uses.capacity() });
        self.entries.clear();
        self.uses.clear();
        self.pending = null;
        if (self.entries.len != 0 or self.uses.len != 0) assert.panic("clearing import notes left {d} imports and {d} uses", .{ self.entries.len, self.uses.len });
    }

    /// Records `piece`, an import's module, binding or explicitly imported name, against the
    /// import statement it belongs to.
    pub fn noteImport(self: *ImportNotes, piece: Piece, source: []const u8) error{LimitExceeded}!void {
        const node = piece.node;
        const text = node.text(source);
        if (text.len == 0) assert.panic("an import's {t} matched the empty {f}; capture a node with text", .{ piece.part, node.where() });
        const entry = try self.entryOf(piece.statement);
        switch (piece.part) {
            .module => entry.spec = node,
            .binding => entry.binding = facts_module.nameHash(text),
            .name => {
                if (entry.named < max_shown) entry.shown[entry.named] = node;
                entry.named += 1;
            },
        }
        if (entry.statement > ts.ts_node_start_byte(node)) assert.panic("{f} is noted against a statement starting after it, at byte {d}", .{ node.where(), entry.statement });
    }

    /// Records the object of a member access; the member that follows completes the use.
    pub fn noteVia(self: *ImportNotes, node: ts.Node) void {
        if (node.id == null) assert.panic("noting a null node as a member access's object; the capture always names a node", .{});
        self.pending = node;
        if (self.pending == null) assert.panic("noting {f} left no member access pending", .{node.where()});
    }

    /// Records that the member `node` is read through the object noted just before it, when both
    /// belong to the same access; uses past the per-file limit are not counted.
    pub fn noteUsed(self: *ImportNotes, node: ts.Node, source: []const u8) void {
        if (node.id == null) assert.panic("noting a null node as a member read; the capture always names a node", .{});
        const via = self.pending orelse return;
        self.pending = null;
        const holder = node.parent() orelse return;
        const object_holder = via.parent() orelse return;
        if (!std.meta.eql(holder.key(), object_holder.key())) return;
        if (self.uses.len == self.uses.capacity()) return;
        const start = ts.ts_node_start_byte(node);
        const end = ts.ts_node_end_byte(node);
        if (end <= start or end > source.len) assert.panic("a member spans bytes {d}..{d} of a {d}-byte file", .{ start, end, source.len });
        self.uses.add(.{ .via = facts_module.nameHash(via.text(source)), .used = facts_module.nameHash(source[start..end]), .start = start, .end = end }) catch unreachable;
    }

    /// Adds each noted import with a module to `facts`, with the distinct names the file uses
    /// through it: those it imports explicitly and the members it reads through its binding.
    pub fn flush(self: *ImportNotes, facts: *facts_module.Facts, source: []const u8) error{LimitExceeded}!void {
        if (facts.path.len == 0) assert.panic("flushing {d} imports before the file is known; set facts.path first", .{self.entries.len});
        const before = facts.imports.len;
        const uses = self.uses.items();
        std.mem.sort(Use, uses, {}, Use.before);
        for (self.entries.items()) |entry| {
            const spec_node = entry.spec orelse continue;
            const used = if (entry.binding != 0) distinctUses(uses, entry.binding) else 0;
            const spec = std.mem.trim(u8, spec_node.text(source), "\"'`");
            if (spec.len == 0) continue;
            try facts.imports.add(.{
                .path = facts.path,
                .language = facts.language,
                .spec = try facts.text.copy(spec),
                .line = entry.line,
                .column = entry.column,
                .names = entry.named + used,
                .shown = try shownNames(facts.text, source, uses, entry),
            });
        }
        if (facts.imports.len - before > self.entries.len) assert.panic("flushed {d} imports from {d} noted", .{ facts.imports.len - before, self.entries.len });
        self.clear();
    }

    fn entryOf(self: *ImportNotes, statement: ts.Node) error{LimitExceeded}!*Entry {
        if (statement.id == null) assert.panic("noting an import against a null statement; importStatement() returns a node of the tree", .{});
        const start = ts.ts_node_start_byte(statement);
        const items = self.entries.items();
        if (items.len > 0 and items[items.len - 1].statement == start) return &items[items.len - 1];
        for (items) |*e| if (e.statement == start) return e;
        const at = ts.ts_node_start_point(statement);
        try self.entries.add(.{ .statement = start, .line = at.row, .column = at.column });
        const added = &self.entries.items()[self.entries.len - 1];
        if (added.statement != start) assert.panic("the import noted at byte {d} was filed at byte {d}", .{ start, added.statement });
        return added;
    }
};

/// Which part of an import a capture names.
pub const Part = enum { module, binding, name };

/// One captured part of an import, and the import statement around it.
pub const Piece = struct { part: Part, statement: ts.Node, node: ts.Node };

/// Where the first use read through `via` sits in `sorted`, ordered by `via` then `used`.
fn firstVia(sorted: []const Use, via: u64) usize {
    if (via == 0) assert.panic("searching {d} uses for the 0 hash; a binding's hash is never 0", .{sorted.len});
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle].via < via) low = middle + 1 else high = middle;
    }
    if (low > sorted.len) assert.panic("searched {d} uses and landed at {d}, past the end", .{ sorted.len, low });
    return low;
}

/// The names an import quotes: those it imports explicitly, then members read through its
/// binding, up to max_shown, separated by ", ".
fn shownNames(text: *memory.Text, source: []const u8, uses: []const Use, entry: Entry) error{LimitExceeded}![]const u8 {
    const named = entry.shown[0..@min(entry.named, max_shown)];
    if (entry.named > 0 and named[0] == null) assert.panic("an import at {d}:{d} names {d} things but quotes none; noteImport() keeps the first", .{ entry.line + 1, entry.column + 1, entry.named });
    var buffer: [max_shown][]const u8 = undefined;
    var count: usize = 0;
    for (named) |n| if (n) |node| {
        buffer[count] = node.text(source);
        count += 1;
    };
    if (entry.binding != 0) {
        var at = firstVia(uses, entry.binding);
        var last: u64 = 0;
        while (count < max_shown and at < uses.len and uses[at].via == entry.binding) : (at += 1) {
            if (uses[at].used == last) continue;
            last = uses[at].used;
            buffer[count] = source[uses[at].start..uses[at].end];
            count += 1;
        }
    }
    if (count > max_shown) assert.panic("quoted {d} names, more than {d}", .{ count, max_shown });
    return text.format("{f}", .{Joined{ .names = buffer[0..count] }});
}

const Joined = struct {
    names: []const []const u8,
    pub fn format(self: Joined, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.names.len > max_shown) assert.panic("joining {d} names, more than the {d} a finding quotes", .{ self.names.len, max_shown });
        for (self.names) |name| if (name.len == 0) assert.panic("joining an empty name among {d}; every quoted name is a captured node's text", .{self.names.len});
        for (self.names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
    }
};

/// How many distinct members `sorted` uses read through `via`.
fn distinctUses(sorted: []const Use, via: u64) u32 {
    if (via == 0) assert.panic("counting {d} uses read through the 0 hash; only imports with a binding count uses", .{sorted.len});
    var at = firstVia(sorted, via);
    var count: u32 = 0;
    var last: u64 = 0;
    while (at < sorted.len and sorted[at].via == via) : (at += 1) {
        if (sorted[at].used == last) continue;
        last = sorted[at].used;
        count += 1;
    }
    if (count > sorted.len) assert.panic("counted {d} distinct members among {d} uses", .{ count, sorted.len });
    return count;
}
