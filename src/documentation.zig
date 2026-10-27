//! Source ranges for declarations and their attached documentation.
const std = @import("std");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const assert = @import("assert.zig");

/// Includes contiguous standalone comments attached to a declaration, without moving its location.
pub fn sourceWithComments(span: ts.Node, source: []const u8, index: *const captures.Index, prefix: ?captures.Id) []const u8 {
    const end_byte = ts.ts_node_end_byte(span);
    if (end_byte > source.len) assert.panic("declaration ends at {d}, beyond its {d}-byte source; pass the source parsed for this node", .{ end_byte, source.len });
    var node = span;
    while (node.parent()) |parent| {
        if (ts.ts_node_start_byte(parent) != ts.ts_node_start_byte(node) and
            !(index.marks(parent, prefix) and ts.ts_node_end_byte(parent) == end_byte)) break;
        node = parent;
    }
    var start = ts.ts_node_start_byte(node);
    while (start > 0) {
        const previous = ts.ts_node_prev_named_sibling(node);
        if (ts.ts_node_is_null(previous)) break;
        const kind = std.mem.span(ts.ts_node_type(previous));
        if (std.mem.indexOf(u8, kind, "comment") == null and !index.marks(previous, prefix)) break;
        const end = ts.ts_node_end_byte(previous);
        const gap = source[end..start];
        if (std.mem.trim(u8, gap, " \t\r\n").len != 0 or std.mem.count(u8, gap, "\n") + @intFromBool(end > 0 and source[end - 1] == '\n') != 1) break;
        const before = ts.ts_node_start_byte(previous);
        const line = if (std.mem.lastIndexOfScalar(u8, source[0..before], '\n')) |at| at + 1 else 0;
        if (std.mem.trim(u8, source[line..before], " \t\r").len != 0) break;
        start = before;
        node = previous;
    }
    if (start > ts.ts_node_start_byte(span)) assert.panic("documentation starts at {d}, after declaration at {d}; only extend the source backwards", .{ start, ts.ts_node_start_byte(span) });
    return source[start..end_byte];
}
