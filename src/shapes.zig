//! Functions with the same structure, so one was most likely copied from the other and its names
//! and values changed: a fix to one is then needed in the other too.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;

/// Records the shape of the closing function's body: the kinds of its syntax nodes in order,
/// without names or values. Tests are left out: they are parallel on purpose.
pub fn recordShape(self: *File, ctx: Context) !void {
    if (ctx.family != .function) assert.panic("{s}: recording the shape of {f}, which is a {t}, not a function; call recordShape() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (!self.checker.enabled.enabled("structural-twins")) return;
    const function = ctx.fact orelse return;
    if (!ctx.body or ctx.is_test or self.index.marks(ctx.node, self.v.test_outer)) return;
    if (ctx.body_start == std.math.maxInt(u32)) assert.panic("{s}: {f} has a body but no recorded start; assign() must set body_start with the first @inner", .{ self.work.facts.path, ctx.node.where() });
    if (self.codeLinesIn(ctx.span) < rules.min_twin_lines) return;
    const shape = bodyShape(self, ctx.span, ctx.body_start);
    if (shape.size < rules.min_twin_nodes) return;
    const facts = self.work.facts;
    try facts.shapes.add(.{ .function = function, .hash = shape.hash, .size = shape.size, .start = ctx.body_start, .end = ts.ts_node_end_byte(ctx.span) });
}

const BodyShape = struct { hash: u64, size: u32 };

/// The kinds of the syntax nodes in `span` from `body_start` on, in order and with their depth,
/// leaving out comments: what two bodies share when only their names and values differ.
fn bodyShape(self: *File, span: ts.Node, body_start: u32) BodyShape {
    if (body_start > ts.ts_node_end_byte(span)) assert.panic("{s}: the body of {f} starts at byte {d}, after the function ends; record body_start from the function's own @inner", .{ self.work.facts.path, span.where(), body_start });
    var hasher = std.hash.Wyhash.init(0);
    var size: u32 = 0;
    var cursor = ts.ts_tree_cursor_new(span);
    defer ts.ts_tree_cursor_delete(&cursor);
    const steps = 2 * @as(usize, ts.ts_node_descendant_count(span)) + 1;
    var descending = true;
    var depth: u32 = 0;
    for (0..steps) |_| {
        const node = ts.ts_tree_cursor_current_node(&cursor);
        if (descending and ts.ts_node_end_byte(node) > body_start and !ts.ts_node_is_extra(node)) {
            const symbol = ts.ts_node_symbol(node);
            hasher.update(std.mem.asBytes(&symbol));
            hasher.update(std.mem.asBytes(&depth));
            size += 1;
        }
        if (descending and ts.ts_tree_cursor_goto_first_child(&cursor)) {
            depth += 1;
            continue;
        }
        if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) {
            descending = true;
            continue;
        }
        if (depth == 0 or !ts.ts_tree_cursor_goto_parent(&cursor)) break;
        depth -= 1;
        descending = false;
    }
    if (size > steps) assert.panic("{s}: hashed {d} nodes of a function with {d} steps to walk; recordShape() must hash each node once", .{ self.work.facts.path, size, steps });
    return .{ .hash = hasher.final(), .size = size };
}
