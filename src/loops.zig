//! What an unbounded loop's fix says: where the loop can stop today, so the reader knows what a
//! limit has to sit alongside.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const check = @import("check.zig");
const hazards = @import("hazards.zig");
const File = check.File;

/// Exits named in a fix; the rest are counted.
const max_shown = 3;

/// The fix for an unbounded loop: the lines where it can stop, a `return` anywhere in it or a
/// `break` that belongs to it, or that nothing in it stops it.
pub fn unboundedFix(self: *File, loop: ts.Node) ![]const u8 {
    const compiled = self.checker.compiled;
    const exit = compiled.id("flow.exit");
    const loop_id = compiled.id("loop.outer");
    const start = ts.ts_node_start_byte(loop);
    const end = ts.ts_node_end_byte(loop);
    if (end > self.source.len) assert.panic("{s}: the loop {f} ends at byte {d}, past the {d}-byte file; pass a node from the tree parsed from this file", .{ self.work.facts.path, loop.where(), end, self.source.len });
    const text = self.work.text;
    const from = text.used;
    var found: usize = 0;
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start + 1, hazards.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != exit or !leaves(self, t.node, loop, loop_id)) continue;
        found += 1;
        if (found > max_shown) continue;
        const separator = if (found == 1) "It stops only at " else ", ";
        _ = try text.format("{s}line {d} (`{s}`)", .{ separator, ts.ts_node_start_point(t.node).row + 1, check.header(t.node.text(self.source)) });
    }
    if (found == 0) return self.say("Nothing in it stops it, so only an error or the process ending does; give it a condition, or a limit such as a maximum number of attempts.", .{});
    if (found > max_shown) _ = try text.format(" and {d} more places", .{found - max_shown});
    _ = try text.copy("; add a limit, such as a maximum number of attempts, and decide what happens when it is reached.");
    const fix = text.buffer[from..text.used];
    if (!std.mem.startsWith(u8, fix, "It stops only at line ")) assert.panic("{s}: the unbounded-loop fix for {f} came out as '{s}'; unboundedFix() must start with the first exit", .{ self.work.facts.path, loop.where(), fix });
    return fix;
}

/// Whether `exit` stops `loop`: a return always does, a continue never does, and a break does
/// unless a loop inside `loop` holds it.
fn leaves(self: *File, exit: ts.Node, loop: ts.Node, loop_id: ?captures.Id) bool {
    const words = exit.text(self.source);
    if (ts.ts_node_end_byte(exit) > ts.ts_node_end_byte(loop)) assert.panic("{s}: the exit {f} ends after the loop {f} it was found in; search only inside the loop", .{ self.work.facts.path, exit.where(), loop.where() });
    if (std.mem.startsWith(u8, words, "return")) return true;
    if (!std.mem.startsWith(u8, words, "break")) return false;
    const at = ts.ts_node_start_byte(exit);
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, ts.ts_node_start_byte(loop) + 1, hazards.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start > at) break;
        if (t.id == loop_id and ts.ts_node_end_byte(t.node) >= ts.ts_node_end_byte(exit)) return false;
    }
    if (at <= ts.ts_node_start_byte(loop)) assert.panic("{s}: the break {f} starts where its loop {f} does; search only inside the loop", .{ self.work.facts.path, exit.where(), loop.where() });
    return true;
}
