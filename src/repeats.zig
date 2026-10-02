//! The same expression written out several times in one function, so a change to it has to be
//! made in every copy, and a reader has to check that the copies really are the same.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const scope = @import("scope.zig");

pub const Repeat = struct { node: ts.Node, hash: u64, size: u32 };
/// Something the code writes to, by the name it starts with: `self` for `self.at += 1`.
pub const Write = struct { at: u32, root: []const u8 };

/// Records what a call changes: the receiver of a method that mutates it, such as `items.pop()`,
/// and anything passed by address, as `&cursor` is.
pub fn noteCallWrites(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: noting what {f} changes, but it is a {t}, not a call; call noteCallWrites() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name", .{ self.work.facts.path, ctx.node.where() });
    if (contains(self.tables.mutating_calls, name)) if (ctx.receiver) |receiver| try noteWrite(self, ctx.node, receiver.text(self.source));
    for (ctx.arguments) |argument| if (argument) |a| {
        const text = a.text(self.source);
        if (std.mem.startsWith(u8, text, "&")) try noteWrite(self, ctx.node, std.mem.trimStart(u8, text[1..], " "));
    };
}

/// Records that the code at `node` writes to `target`: an assignment's target, a receiver a method
/// changes, or a value passed by address, as `&cursor` is.
pub fn noteWrite(self: *File, node: ts.Node, target: []const u8) !void {
    if (!self.checker.enabled.enabled("duplicated-expression")) return;
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: the write at {f} ends past the {d}-byte file; pass a node from this file's tree", .{ self.work.facts.path, node.where(), self.source.len });
    const name = if (std.mem.startsWith(u8, target, "mut ")) target[4..] else target;
    const end = std.mem.indexOfNone(u8, name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$@") orelse name.len;
    if (end == 0) return;
    if (end > name.len) assert.panic("{s}: the written name runs {d} bytes into the {d}-byte target '{s}'; noteWrite() must slice within it", .{ self.work.facts.path, end, name.len, name });
    try self.s.writes.add(.{ .at = ts.ts_node_start_byte(node), .root = name[0..end] });
}

/// Records an expression captured as `@expression.repeatable` against the function it is in, when
/// it computes something (a call, an index or arithmetic, not a plain member read such as
/// `ctx.node`), is on one line, is used rather than called for its effect or returned on the way
/// out, isn't part of an assertion, and is long enough that writing it again is duplication
/// rather than idiom.
pub fn noteRepeatable(self: *File, node: ts.Node) !void {
    if (!self.checker.enabled.enabled("duplicated-expression")) return;
    if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) assert.panic("{s}: the expression {f} covers no text; put @expression.repeatable on the whole expression in the language's zanity.scm", .{ self.work.facts.path, node.where() });
    if (self.enclosingFunction() == null or self.innermost(.assertion) != null) return;
    if (self.index.marks(node, self.v.chain_link)) return;
    if (self.index.marks(node, self.checker.compiled.id("call.discarded"))) return;
    if (self.index.marks(node, self.checker.compiled.id("expression.returned"))) return;
    const text = node.text(self.source);
    if (std.mem.indexOfScalar(u8, text, '\n') != null) return;
    var hasher = std.hash.Wyhash.init(0);
    var size: u32 = 0;
    for (text) |c| if (!std.ascii.isWhitespace(c)) {
        hasher.update(&.{c});
        size += 1;
    };
    if (size < rules.min_repeated_expression) return;
    if (mutates(self, text)) return;
    if (size > text.len) assert.panic("{s}: counted {d} visible bytes in the {d}-byte expression {f}; noteRepeatable() must count each byte once", .{ self.work.facts.path, size, text.len, node.where() });
    try self.s.repeats.add(.{ .node = node, .hash = hasher.final(), .size = size });
}

/// Whether the expression calls, or names, a method that changes state, such as `items.pop()`,
/// whose copies each do something, so they aren't duplicates.
fn mutates(self: *File, text: []const u8) bool {
    if (text.len == 0) assert.panic("{s}: asked whether an empty expression changes state; the @expression.repeatable capture matched no text", .{self.work.facts.path});
    const callee = if (text[text.len - 1] == ')') text[0 .. std.mem.indexOfScalar(u8, text, '(') orelse return false] else text;
    const name = callee[if (std.mem.lastIndexOfAny(u8, callee, ".:>")) |at| at + 1 else 0..];
    if (name.len > callee.len) assert.panic("{s}: the called name '{s}' is longer than its callee '{s}'; mutates() must slice the name out of the callee", .{ self.work.facts.path, name, callee });
    return name.len > 0 and contains(self.tables.mutating_calls, name);
}

/// Reports each expression written `rules.min_repeats` times or more in the function that is
/// closing, once, at its first copy; an expression inside a larger one that is reported is not.
/// Then forgets the function's expressions, so the enclosing function sees only its own.
pub fn checkRepeats(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: checking repeated expressions of {f}, which is a {t}, not a function; call checkRepeats() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const all = self.s.repeats.items();
    if (ctx.repeat_mark > all.len) assert.panic("{s}: '{s}' marked its expressions from {d}, but only {d} are recorded; closeFunction() must forget only the closing function's expressions", .{ self.work.facts.path, name, ctx.repeat_mark, all.len });
    const mine = all[ctx.repeat_mark..];
    defer self.s.repeats.len = ctx.repeat_mark;
    std.mem.sort(Repeat, mine, {}, biggestFirst);
    var groups: [64]CopyGroup = undefined;
    var reported: usize = 0;
    var i: usize = 0;
    while (i < mine.len) {
        const group: CopyGroup = .{ .start = i, .end = groupEnd(mine, i) };
        i = group.end;
        const copies = mine[group.start..group.end];
        if (copies.len < rules.min_repeats or covered(mine, groups[0..reported], copies)) continue;
        if (changesBetween(self, copies)) continue;
        const first = earliest(copies);
        _ = try self.report(first, "duplicated-expression", try self.say("'{s}' is written {d} times in '{s}', so a change to it has to be made in every copy.", .{ first.text(self.source), copies.len, name }));
        if (reported < groups.len) {
            groups[reported] = group;
            reported += 1;
        }
    }
    if (reported > groups.len) assert.panic("{s}: kept {d} reported groups in room for {d}; checkRepeats() must stop keeping them when full", .{ self.work.facts.path, reported, groups.len });
}

const CopyGroup = struct { start: usize, end: usize };

/// Whether something the expression reads is written between its first copy and its last, as
/// `self.at` is between the reads of `self.bytes[self.at]` in a parser, so the copies differ.
fn changesBetween(self: *File, copies: []const Repeat) bool {
    if (copies.len < 2) assert.panic("{s}: asked whether {d} copy changes between copies; checkRepeats() only asks about groups of min_repeats", .{ self.work.facts.path, copies.len });
    var first: u32 = std.math.maxInt(u32);
    var last: u32 = 0;
    for (copies) |c| {
        first = @min(first, ts.ts_node_end_byte(c.node));
        last = @max(last, ts.ts_node_start_byte(c.node));
    }
    if (first == std.math.maxInt(u32)) assert.panic("{s}: the {d} copies of an expression end nowhere; changesBetween() must take each copy's end", .{ self.work.facts.path, copies.len });
    const text = copies[0].node.text(self.source);
    for (self.s.writes.items()) |w| {
        if (w.root.len == 0) assert.panic("{s}: a write at byte {d} has no name; noteWrite() must skip targets without one", .{ self.work.facts.path, w.at });
        if (w.at <= first or w.at >= last) continue;
        if (scope.containsWord(text, w.root)) return true;
    }
    return false;
}

fn biggestFirst(_: void, a: Repeat, b: Repeat) bool {
    if (a.size == 0 or b.size == 0) assert.panic("sorting an expression with no visible characters; noteRepeatable() records only those of min_repeated_expression or more", .{});
    if (a.node.id == null or b.node.id == null) assert.panic("sorting a repeated expression with no node; noteRepeatable() records captured nodes", .{});
    if (a.size != b.size) return a.size > b.size;
    if (a.hash != b.hash) return a.hash < b.hash;
    return ts.ts_node_start_byte(a.node) < ts.ts_node_start_byte(b.node);
}

/// Where the run of copies of `items[start]` ends.
fn groupEnd(items: []const Repeat, start: usize) usize {
    if (start >= items.len) assert.panic("a group of repeated expressions starts at {d} of {d}; checkRepeats() must stop at the end", .{ start, items.len });
    var end = start + 1;
    while (end < items.len and items[end].hash == items[start].hash and items[end].size == items[start].size) end += 1;
    if (end <= start) assert.panic("the group starting at {d} ends at {d}; a group holds at least the expression it starts with", .{ start, end });
    return end;
}

/// Whether every copy sits inside a copy of an expression already reported, like `item.get` inside
/// `item.get("price", 0)`, so the larger finding covers it.
fn covered(items: []const Repeat, reported: []const CopyGroup, copies: []const Repeat) bool {
    if (copies.len == 0) assert.panic("asked whether an empty group of copies is covered; groupEnd() always returns at least one", .{});
    if (reported.len > 64) assert.panic("{d} reported groups, more than checkRepeats() keeps; it must stop recording at its array's length", .{reported.len});
    if (reported.len == 0) return false;
    for (copies) |copy| {
        if (!insideAny(items, reported, copy.node)) return false;
    }
    return true;
}

fn insideAny(items: []const Repeat, reported: []const CopyGroup, node: ts.Node) bool {
    if (node.id == null) assert.panic("asked whether a null node is inside a reported expression; pass a copy's node", .{});
    for (reported) |group| {
        if (group.end > items.len) assert.panic("a reported group ends at {d}, past the {d} expressions; checkRepeats() records groups from groupEnd()", .{ group.end, items.len });
        for (items[group.start..group.end]) |r| {
            if (ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(r.node) and ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(r.node)) return true;
        }
    }
    return false;
}

fn earliest(copies: []const Repeat) ts.Node {
    if (copies.len == 0) assert.panic("asked for the first of no copies; groupEnd() always returns at least one", .{});
    var first = copies[0].node;
    for (copies[1..]) |c| if (ts.ts_node_start_byte(c.node) < ts.ts_node_start_byte(first)) {
        first = c.node;
    };
    if (ts.ts_node_start_byte(first) > ts.ts_node_start_byte(copies[0].node)) assert.panic("the earliest copy {f} starts after another copy {f}; earliest() must keep the smaller start", .{ first.where(), copies[0].node.where() });
    return first;
}
