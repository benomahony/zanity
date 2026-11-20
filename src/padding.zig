//! Struct padding: a struct whose fields sit in the order they are written, and take more bytes
//! that way, padded to each field's alignment, than ordered from the largest alignment down.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const File = check.File;

/// The most fields padded-struct sizes in one struct; a larger one is left alone.
const max_layout_fields = 64;

const Slot = struct { size: u32, alignment: u32 };

/// A struct whose fields sit in the order they are written, and take more bytes in that order,
/// padded to each field's alignment, than ordered from the largest alignment to the smallest.
/// A struct with a field whose size the language's tables don't give is left alone.
pub fn checkPadding(self: *File, node: ts.Node) !void {
    if (!self.checker.enabled.enabled("padded-struct") or self.tables.field_sizes.len == 0) return;
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: the struct {f} ends past the {d}-byte file; pass a node from this file's tree", .{ self.work.facts.path, node.where(), self.source.len });
    var slots: [max_layout_fields]Slot = undefined;
    const count = fields(self, node, &slots) orelse return;
    if (count < 2) return;
    if (count > slots.len) assert.panic("{s}: the struct {f} has {d} fields in room for {d}; fields() must stop at its array's length", .{ self.work.facts.path, node.where(), count, slots.len });
    const used = slots[0..count];
    const written = layoutSize(used);
    std.mem.sort(Slot, used, {}, widerFirst);
    const best = layoutSize(used);
    if (best > written) assert.panic("{s}: ordering the fields of {f} by alignment took {d} bytes, more than the {d} as written; widest-first never adds padding", .{ self.work.facts.path, node.where(), best, written });
    if (best == written) return;
    const declared_by = node.parent() orelse node;
    const same_line = ts.ts_node_start_point(declared_by).row == ts.ts_node_start_point(node).row;
    const shown = check.header((if (same_line) declared_by else node).text(self.source));
    _ = try self.report(node, "padded-struct", try self.say("'{s}' takes {d} bytes with its fields in the order written, but {d} with them ordered from the largest alignment to the smallest, so every copy carries {d} bytes of padding.", .{ shown, written, best, written - best }));
}

/// The size and alignment of each stored field of `structure`, in order, or null when one can't
/// be sized: its type isn't in the language's tables, or it declares several fields at once.
fn fields(self: *File, structure: ts.Node, slots: *[max_layout_fields]Slot) ?usize {
    const compiled = self.checker.compiled;
    const member = compiled.id("layout.member") orelse return null;
    const field = compiled.id("layout.field") orelse return null;
    const unknown = compiled.id("layout.unknown");
    const skip = compiled.id("layout.skip");
    const start = ts.ts_node_start_byte(structure);
    const end = ts.ts_node_end_byte(structure);
    if (end <= start) assert.panic("{s}: the struct {f} covers no text; capture the whole struct as @layout.struct", .{ self.work.facts.path, structure.where() });
    var count: usize = 0;
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, captures.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (unknown != null and t.id == unknown.? and ownedBy(self, t.node, structure)) return null;
        if (t.id != member or !ownedBy(self, t.node, structure)) continue;
        if (skip != null and self.index.marks(t.node, skip.?)) continue;
        const slot = sizeOf(self, t.node, field) orelse return null;
        if (count == slots.len) return null;
        slots[count] = slot;
        count += 1;
    }
    if (count > slots.len) assert.panic("{s}: counted {d} fields of {f} in room for {d}", .{ self.work.facts.path, count, structure.where(), slots.len });
    return count;
}

/// Whether the nearest struct around `node` is `structure`, so a nested struct's fields aren't
/// counted as its own.
fn ownedBy(self: *File, node: ts.Node, structure: ts.Node) bool {
    const layout = self.v.layout_struct orelse return false;
    if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(structure)) assert.panic("{s}: {f} starts before the struct {f} it was found in", .{ self.work.facts.path, node.where(), structure.where() });
    var up = node.parent();
    while (up) |outer| : (up = outer.parent()) {
        if (outer.eql(structure)) return true;
        if (self.index.marks(outer, layout)) return false;
    }
    if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(structure)) assert.panic("{s}: {f} ends after the struct {f} it was found in", .{ self.work.facts.path, node.where(), structure.where() });
    return false;
}

/// The size and alignment of the one type `member` declares, from the language's tables.
fn sizeOf(self: *File, member: ts.Node, field: captures.Id) ?Slot {
    const start = ts.ts_node_start_byte(member);
    const end = ts.ts_node_end_byte(member);
    if (end <= start) assert.panic("{s}: the member {f} covers no text; capture the whole declaration as @layout.member", .{ self.work.facts.path, member.where() });
    var found: ?ts.Node = null;
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, captures.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != field) continue;
        if (found != null) return null;
        found = t.node;
    }
    const written = std.mem.trim(u8, (found orelse return null).text(self.source), " \t\r\n");
    if (written.len == 0) assert.panic("{s}: the field type in {f} has no text; capture the type itself as @layout.field", .{ self.work.facts.path, member.where() });
    for (self.tables.field_sizes) |entry| {
        const matches = if (entry.prefix) std.mem.startsWith(u8, written, entry.type) else std.mem.eql(u8, written, entry.type);
        if (matches) return .{ .size = entry.size, .alignment = entry.alignment };
    }
    return null;
}

/// The bytes fields take laid out in the order given, each at the next multiple of its alignment,
/// with the whole rounded up to the largest alignment so an array of them stays aligned.
fn layoutSize(slots: []const Slot) u32 {
    if (slots.len == 0) assert.panic("sized a struct with no fields; checkPadding() needs at least two", .{});
    var offset: u32 = 0;
    var widest: u32 = 1;
    for (slots) |slot| {
        if (slot.alignment == 0 or !std.math.isPowerOfTwo(slot.alignment)) assert.panic("a field aligned to {d} bytes; give each languages/tables.zon field size a power of two alignment", .{slot.alignment});
        offset = std.mem.alignForward(u32, offset, slot.alignment) + slot.size;
        widest = @max(widest, slot.alignment);
    }
    return std.mem.alignForward(u32, offset, widest);
}

fn widerFirst(_: void, a: Slot, b: Slot) bool {
    if (a.alignment == 0 or b.alignment == 0) assert.panic("sorting a field aligned to 0 bytes; give each languages/tables.zon field size an alignment", .{});
    if (a.size == 0 and b.size == 0) assert.panic("sorting two fields of no size; give each languages/tables.zon field size its bytes", .{});
    return a.alignment > b.alignment;
}
