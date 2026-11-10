//! Renaming a name everywhere it is written: one edit for each whole-word use of it in the checked
//! files, which `check --fix` makes together or not at all.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const naming = @import("naming.zig");
const Finding = @import("facts.zig").Finding;

/// Names one run renames; findings past them are reported without an edit.
pub const max_renames = 64;

/// A name to change from `old` to `new`. Found uses are
/// counted, and `taken` holds where `new` is already written, which rules the rename out.
pub const Rename = struct {
    old: []const u8,
    new: []const u8,
    uses: usize = 0,
    files: usize = 0,
    taken: ?Place = null,
};

/// Where a rename's new name is already written, or the file that couldn't be read to look.
pub const Place = struct { path: []const u8, line: ?u32 };

/// The renames a run asks for, numbered from 1 in `Finding.rename`.
pub const Pending = struct {
    renames: [max_renames]Rename = undefined,
    len: usize = 0,

    /// The number of the rename from `old` to `new`, added unless an earlier finding asked for it;
    /// 0 when it can't be made: `old` is one word, which prose uses too, or the run has no room.
    pub fn ask(self: *Pending, old: []const u8, new: []const u8) u32 {
        if (std.mem.eql(u8, old, new)) assert.panic("renaming '{s}' to itself; respelled() must change the alias", .{old});
        for (self.renames[0..self.len], 1..) |r, id| if (std.mem.eql(u8, r.old, old) and std.mem.eql(u8, r.new, new)) return @intCast(id);
        if (wordCount(old) < 2 or self.len == max_renames) return 0;
        self.renames[self.len] = .{ .old = old, .new = new };
        self.len += 1;
        if (self.len > max_renames) assert.panic("{d} renames in room for {d}", .{ self.len, max_renames });
        return @intCast(self.len);
    }
};

fn wordCount(name: []const u8) usize {
    if (name.len == 0) assert.panic("counting the words of an empty name; a definition always has one", .{});
    var words: naming.Words = .{ .text = name };
    var count: usize = 0;
    while (words.next()) |_| count += 1;
    if (count > name.len) assert.panic("'{s}' has {d} words in {d} bytes; Words gives at most one per byte", .{ name, count, name.len });
    return count;
}

/// Where the checked files are read from: `buffer` holds one at a time.
pub const Reading = struct { io: std.Io, buffer: []u8 };

/// Adds to `edits` one edit for each use of each rename's old name in `files`, numbered as the
/// rename, then takes out the edits of every rename whose new name is already used somewhere.
pub fn findUses(sources: Reading, pending: *Pending, files: []const []const u8, edits: *memory.Bounded(Finding)) error{LimitExceeded}!void {
    const renames = pending.renames[0..pending.len];
    if (renames.len == 0) assert.panic("finding the uses of no renames; call findUses() only when a finding asked for one", .{});
    const before = edits.len;
    for (files) |path| {
        const source = std.Io.Dir.cwd().readFile(sources.io, path, sources.buffer) catch {
            for (renames) |*r| r.taken = r.taken orelse .{ .path = path, .line = null };
            continue;
        };
        for (renames, 1..) |*r, id| {
            if (r.taken == null) if (firstUse(source, r.new)) |line| {
                r.taken = .{ .path = path, .line = line };
            };
            const found = try addUses(.{ .path = path, .source = source, .id = @intCast(id), .rename = r.* }, edits);
            r.uses += found;
            r.files += @intFromBool(found > 0);
        }
    }
    var kept = before;
    for (edits.items()[before..]) |e| {
        if (renames[e.rename - 1].taken != null) continue;
        edits.items()[kept] = e;
        kept += 1;
    }
    edits.len = kept;
    if (kept < before) assert.panic("dropped edits from before this run's renames: {d} kept of {d}", .{ kept, before });
}

/// One file's uses of one rename's old name.
const Uses = struct { path: []const u8, source: []const u8, id: u32, rename: Rename };

fn addUses(uses: Uses, edits: *memory.Bounded(Finding)) error{LimitExceeded}!usize {
    const old = uses.rename.old;
    if (old.len == 0) assert.panic("renaming an empty name in {s}; a definition always has one", .{uses.path});
    var found: usize = 0;
    var line: u32 = 0;
    var line_start: usize = 0;
    var counted: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, uses.source, at, old)) |start| : (at = start + old.len) {
        if (!wholeWord(uses.source, start, old)) continue;
        for (uses.source[counted..start], counted..) |c, i| if (c == '\n') {
            line += 1;
            line_start = i + 1;
        };
        counted = start;
        try edits.add(.{
            .path = uses.path,
            .line = line,
            .column = @intCast(start - line_start),
            .rule = "non-canonical-term",
            .message = "",
            .edit = .{ .start = @intCast(start), .end = @intCast(start + old.len), .replacement = uses.rename.new },
            .rename = uses.id,
            .companion = true,
        });
        found += 1;
    }
    if (found > uses.source.len) assert.panic("{d} uses of '{s}' in the {d} bytes of {s}", .{ found, old, uses.source.len, uses.path });
    return found;
}

/// The line `name` is first written on as a whole word, if it is.
fn firstUse(source: []const u8, name: []const u8) ?u32 {
    if (name.len == 0) assert.panic("looking for an empty name in {d} bytes; a rename's new name is never empty", .{source.len});
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, name)) |start| : (at = start + name.len) {
        if (!wholeWord(source, start, name)) continue;
        const line = std.mem.count(u8, source[0..start], "\n");
        if (line > source.len) assert.panic("'{s}' is on line {d} of {d} bytes", .{ name, line, source.len });
        return @intCast(line);
    }
    return null;
}

/// Whether `name`, at `start` in `source`, is the whole of a word there: no identifier byte
/// touches it on either side. A dash joins words only in a name that has one.
fn wholeWord(source: []const u8, start: usize, name: []const u8) bool {
    if (!std.mem.startsWith(u8, source[start..], name)) assert.panic("'{s}' is not at byte {d}; pass where indexOfPos() found it", .{ name, start });
    const dashes = std.mem.indexOfScalar(u8, name, '-') != null;
    const end = start + name.len;
    if (end > source.len) assert.panic("'{s}' at byte {d} runs past the {d}-byte source", .{ name, start, source.len });
    if (start > 0 and identifier(source[start - 1], dashes)) return false;
    return end == source.len or !identifier(source[end], dashes);
}

fn identifier(c: u8, dashes: bool) bool {
    const part = std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80 or (dashes and c == '-');
    if (part and std.ascii.isWhitespace(c)) assert.panic("byte {d} is both whitespace and part of a name", .{c});
    if (part and c == '-' and !dashes) assert.panic("a dash counted as part of a name that has none", .{});
    return part;
}

test "a rename finds whole-word uses only, and none when the new name is taken" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source = "send_bill(x)\nresend_bill()\n  send_bill\n\"send_bill_now\"\n";
    var edits = try memory.Bounded(Finding).initBounded(arena_state.allocator(), 8, "test renames");
    const rename: Rename = .{ .old = "send_bill", .new = "send_invoice" };
    try std.testing.expectEqual(@as(usize, 2), try addUses(.{ .path = "a.py", .source = source, .id = 1, .rename = rename }, &edits));
    try std.testing.expectEqual(@as(u32, 2), edits.items()[1].line);
    try std.testing.expectEqual(@as(u32, 2), edits.items()[1].column);
    try std.testing.expectEqual(@as(?u32, 1), firstUse(source, "resend_bill"));
    try std.testing.expectEqual(@as(?u32, null), firstUse(source, "send_bill_"));
    var pending: Pending = .{};
    try std.testing.expectEqual(@as(u32, 0), pending.ask("bill", "invoice"));
    try std.testing.expectEqual(@as(u32, 1), pending.ask("send_bill", "send_invoice"));
    try std.testing.expectEqual(@as(u32, 1), pending.ask("send_bill", "send_invoice"));
}
