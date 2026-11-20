//! The data layout checks: work a loop repeats on every pass that it could do once, such as
//! allocating, or growing a collection one element at a time when its length is known first.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;

/// The loop that runs `call` on every pass: the innermost loop inside `function`, unless `call`
/// sits in that loop's iterable, which runs once.
fn passLoop(self: *File, call: ts.Node, function: *const Context) ?*Context {
    const loop = self.innermost(.loop) orelse return null;
    if (ts.ts_node_start_byte(loop.node) < ts.ts_node_start_byte(function.node)) return null;
    if (ts.ts_node_start_byte(call) < ts.ts_node_start_byte(loop.node)) assert.panic("{s}: the call {f} starts before its loop {f}; innermost() must return a loop still open around it", .{ self.work.facts.path, call.where(), loop.node.where() });
    if (ts.ts_node_end_byte(call) > ts.ts_node_end_byte(loop.node)) assert.panic("{s}: the call {f} ends after its loop {f}; innermost() must return a loop still open around it", .{ self.work.facts.path, call.where(), loop.node.where() });
    const iterable = loop.iterable orelse return loop;
    if (ts.ts_node_start_byte(call) >= ts.ts_node_start_byte(iterable) and ts.ts_node_end_byte(call) <= ts.ts_node_end_byte(iterable)) return null;
    return loop;
}

/// An allocating call on every pass of a loop; growth calls are left to checkGrowth, which knows
/// whether the collection was sized first.
pub fn checkAllocationInLoop(self: *File, ctx: Context, function: *const Context, shown: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking the allocation in {f}, which is a {t}, not a call; call checkAllocationInLoop() only for calls", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (function.family != .function) assert.panic("{s}: the allocation {f} belongs to a {t}, not a function; pass enclosingFunction()", .{ self.work.facts.path, ctx.node.where(), function.family });
    const loop = passLoop(self, ctx.node, function) orelse return;
    const owner = function.name.?.text(self.source);
    _ = try self.report(ctx.node, "allocation-in-loop", try self.say("'{s}' allocates on every pass of the loop on line {d} of '{s}', so its cost grows with the data and the allocations scatter it across memory.", .{ shown, ts.ts_node_start_point(loop.node).row + 1, owner }));
}

/// A call from the language's growth calls, such as `push` or `append`, that is all a loop over a
/// collection does, adding to a collection the function did not size before the loop.
pub fn checkGrowth(self: *File, ctx: Context, matched: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking the growth in {f}, which is a {t}, not a call; call checkGrowth() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (matched.len == 0) assert.panic("{s}: the growth call {f} matched an empty table entry; remove it from languages/tables.zon", .{ self.work.facts.path, ctx.node.where() });
    if (self.inTest() or self.inTestFile()) return;
    const function = self.enclosingFunction() orelse return;
    const loop = passLoop(self, ctx.node, function) orelse return;
    if (loop.iterable == null) return;
    const named_by_receiver = ctx.receiver != null and std.mem.indexOfScalar(u8, matched, '.') == null;
    const collection = (if (named_by_receiver) ctx.receiver else ctx.arguments[0]) orelse return;
    const name = collection.text(self.source);
    if (std.mem.indexOfAny(u8, name, "([") != null) return;
    if (!onlyStatement(self, loop.node, ctx.node)) return;
    if (sized(self.source[ts.ts_node_start_byte(function.node)..ts.ts_node_start_byte(loop.node)], name, self.tables.reserve_calls)) return;
    if (try self.report(ctx.node, "append-without-reserve", try self.say("'{s}' grows by one element on every pass of the loop on line {d}, though that loop's length is known before it starts, so it reallocates and copies as it grows.", .{ check.header(name), ts.ts_node_start_point(loop.node).row + 1 }))) {
        if (self.tables.reserve_calls.len == 0) self.s.diagnostics.last().?.fix = try self.say("Build '{s}' in one step from what the loop walks, such as with a comprehension or map, rather than adding to it pass by pass.", .{check.header(name)});
    }
}

/// Whether `call` is all the loop does: every line of the loop after its first is the call's, or
/// holds only braces, brackets or `end`. A loop that filters or does more can't be sized from its
/// length or written as one comprehension.
fn onlyStatement(self: *File, loop: ts.Node, call: ts.Node) bool {
    const first = ts.ts_node_start_point(loop).row;
    const from = ts.ts_node_start_point(call).row;
    const to = ts.ts_node_end_point(call).row;
    if (from < first) assert.panic("{s}: the call {f} starts above its loop {f}; pass the loop that encloses it", .{ self.work.facts.path, call.where(), loop.where() });
    if (to > ts.ts_node_end_point(loop).row) assert.panic("{s}: the call {f} ends below its loop {f}; pass the loop that encloses it", .{ self.work.facts.path, call.where(), loop.where() });
    var lines = std.mem.splitScalar(u8, loop.text(self.source), '\n');
    _ = lines.next();
    var row = first;
    while (lines.next()) |line| {
        row += 1;
        if (row >= from and row <= to) continue;
        const rest = std.mem.trim(u8, line, " \t\r{}();");
        if (rest.len > 0 and !std.mem.eql(u8, rest, "end")) return false;
    }
    return true;
}

/// Whether a line of `before` names `collection` and calls one of `reserves` with arguments,
/// such as `out.reserve(n)` or `Vec::with_capacity(n)`, sizing it before the loop.
fn sized(before: []const u8, collection: []const u8, reserves: []const []const u8) bool {
    if (collection.len == 0) assert.panic("asked whether an empty collection name was sized; pass the growth call's receiver or first argument", .{});
    if (reserves.len > 32) assert.panic("checking '{s}' against {d} reserve calls; more than 32 means the table in languages/tables.zon is wrong", .{ collection, reserves.len });
    var lines = std.mem.splitScalar(u8, before, '\n');
    while (lines.next()) |line| {
        if (!names(line, collection)) continue;
        for (reserves) |reserve| if (callsWithArguments(line, reserve)) return true;
    }
    return false;
}

/// Whether `line` writes `word` with no identifier character on either side.
fn names(line: []const u8, word: []const u8) bool {
    if (word.len == 0) assert.panic("looked for an empty word in '{s}'; pass the collection's name", .{line});
    if (line.len > std.math.maxInt(u32)) assert.panic("a line of {d} bytes is longer than any file zanity checks; split the source into lines first", .{line.len});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, word)) |at| : (from = at + 1) {
        const before_ok = at == 0 or !(std.ascii.isAlphanumeric(line[at - 1]) or line[at - 1] == '_');
        const after = at + word.len;
        if (before_ok and (after == line.len or !(std.ascii.isAlphanumeric(line[after]) or line[after] == '_'))) return true;
    }
    return false;
}

/// Whether `line` writes `callee` and then opens a call with at least one argument.
fn callsWithArguments(line: []const u8, callee: []const u8) bool {
    if (callee.len == 0) assert.panic("a reserve call in languages/tables.zon is empty, checking '{s}'; remove it", .{line});
    if (std.mem.indexOfScalar(u8, callee, '(') != null) assert.panic("the reserve call '{s}' includes a parenthesis; name only the callee in languages/tables.zon", .{callee});
    const at = std.mem.indexOf(u8, line, callee) orelse return false;
    const open = std.mem.indexOfScalarPos(u8, line, at + callee.len, '(') orelse return false;
    const rest = std.mem.trimStart(u8, line[open + 1 ..], " \t");
    return rest.len > 0 and rest[0] != ')';
}
