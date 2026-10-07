//! A run of statements in a long function that depends on little around it: it reads a few names
//! set before it, sets at most one that is read after it, and doesn't return or break out, so it
//! can move into a function of its own unchanged.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const check = @import("check.zig");
const hazards = @import("hazards.zig");
const facts_module = @import("facts.zig");
const File = check.File;
const Context = check.Context;
const header = check.header;

/// Statements a body is searched in; a longer body is searched in its first this-many.
const max_statements = 128;
/// Distinct names a body is tracked with; names past it are not tracked.
const max_names = 256;
const Mask = u128;

/// Which statements declare a name, set it whole, change a part of it (`x.y = 1`), and read it.
const Tracked = struct { hash: u64, text: []const u8, declared: Mask = 0, assigned: Mask = 0, touched: Mask = 0, read: Mask = 0, parameter: bool = false };

const Body = struct {
    statements: [max_statements]ts.Node = undefined,
    count: usize = 0,
    names: [max_names]Tracked = undefined,
    name_count: usize = 0,
    /// Statements holding a return, or a break or continue that leaves them.
    exits: Mask = 0,
    ids: FlowIds = undefined,

    fn nameFor(self: *Body, text: []const u8) ?*Tracked {
        if (text.len == 0) assert.panic("tracking a name with no text; trackName() must skip empty names", .{});
        const hash = facts_module.nameHash(text);
        for (self.names[0..self.name_count]) |*n| if (n.hash == hash) return n;
        if (self.name_count == max_names) return null;
        self.names[self.name_count] = .{ .hash = hash, .text = text };
        self.name_count += 1;
        if (self.name_count > max_names) assert.panic("tracked {d} names in room for {d}; nameFor() must stop adding at max_names", .{ self.name_count, max_names });
        return &self.names[self.name_count - 1];
    }

    /// Which top-level statement holds byte `at`, if any.
    fn statementAt(self: *const Body, at: u32) ?usize {
        if (self.count == 0) assert.panic("finding the statement at byte {d} of a body with none; readBody() returns before searching an empty body", .{at});
        if (self.count > max_statements) assert.panic("{d} statements in room for {d}; gather() must stop at max_statements", .{ self.count, max_statements });
        for (self.statements[0..self.count], 0..) |s, i| {
            if (at >= ts.ts_node_start_byte(s) and at < ts.ts_node_end_byte(s)) return i;
            if (at < ts.ts_node_start_byte(s)) return null;
        }
        return null;
    }
};

const Window = struct { start: usize, end: usize, inputs: [rules.max_parameters]*const Tracked = undefined, input_count: usize = 0, output: ?*const Tracked = null };

/// Reports, in a long function, the longest run of top-level statements that could move into a
/// function of its own; when long-function reported the function, the run becomes its fix instead.
pub fn checkExtractable(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: looking for a block to extract from {f}, which is a {t}, not a function; call checkExtractable() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the function {f} has an empty name; capture its identifier as @function.name", .{ self.work.facts.path, ctx.node.where() });
    if (ctx.is_test or ctx.inner == null or self.codeLinesIn(ctx.span) < rules.min_extract_lines) return;
    const long = if (self.s.diagnostics.last()) |d| std.mem.eql(u8, d.rule, "long-function") and d.line == ts.ts_node_start_point(ctx.name.?).row else false;
    if (!long and !self.checker.enabled.enabled("extractable-block")) return;
    var body: Body = .{};
    const window = (if (readBody(self, ctx, &body)) best(&body) else null) orelse {
        if (long) self.s.diagnostics.last().?.fix = try largestStepFix(self, ctx, name, &body);
        return;
    };
    const message = try windowMessage(self, &body, window, name);
    if (long) {
        self.s.diagnostics.last().?.fix = message;
        return;
    }
    _ = try self.report(body.statements[window.start], "extractable-block", message);
}

/// What a movable run of statements needs and gives back, so it can become a function.
fn windowMessage(self: *File, body: *const Body, window: Window, name: []const u8) ![]const u8 {
    if (window.end > body.count or window.start >= window.end) assert.panic("{s}: the block of '{s}' is statements {d}..{d} of {d}; best() returns a run inside the body", .{ self.work.facts.path, name, window.start, window.end, body.count });
    const first = ts.ts_node_start_point(body.statements[window.start]).row + 1;
    const last = ts.ts_node_end_point(body.statements[window.end - 1]).row + 1;
    const text = self.work.text;
    const start = text.used;
    _ = try text.format("Lines {d}-{d} of '{s}' need only ", .{ first, last, name });
    if (window.input_count == 0) _ = try text.copy("what they set themselves");
    for (window.inputs[0..window.input_count], 0..) |input, i| {
        _ = try text.format("{s}'{s}'", .{ if (i == 0) "" else if (i + 1 == window.input_count) " and " else ", ", input.text });
    }
    if (window.output) |output| _ = try text.format(" and give back only '{s}'", .{output.text}) else _ = try text.copy(" and set nothing read after them");
    _ = try text.copy(", so they can move into a function of their own.");
    if (last < first) assert.panic("{s}: the block of '{s}' ends on line {d}, before it starts on {d}", .{ self.work.facts.path, name, last, first });
    return text.buffer[start..text.used];
}

/// When no run of statements can move out as it is: the longest top-level step of the function,
/// where splitting it should start.
fn largestStepFix(self: *File, ctx: Context, name: []const u8, body: *Body) ![]const u8 {
    if (body.count == 0) listStatements(self, ctx, body);
    if (body.count > max_statements) assert.panic("{s}: '{s}' lists {d} statements in room for {d}; listStatements() stops at max_statements", .{ self.work.facts.path, name, body.count, max_statements });
    var largest: ?ts.Node = null;
    var largest_lines: u32 = 0;
    for (body.statements[0..body.count]) |statement| {
        const lines = ts.ts_node_end_point(statement).row - ts.ts_node_start_point(statement).row + 1;
        if (lines <= largest_lines) continue;
        largest = statement;
        largest_lines = lines;
    }
    const step = largest orelse return self.say("Move a self-contained step of '{s}' into its own function.", .{name});
    const first = ts.ts_node_start_point(step).row + 1;
    if (largest_lines == 0) assert.panic("{s}: the longest step of '{s}' spans no lines; a statement spans at least its own", .{ self.work.facts.path, name });
    return self.say("Its longest step is lines {d}-{d}, starting `{s}`; move that, or the steps inside it, into a function of its own, passing in what it reads.", .{ first, first + largest_lines - 1, header(step.text(self.source)) });
}

/// The fix for a function with too many decisions: the top-level step that makes the most of
/// them, which is where splitting it pays off most.
pub fn decisionsFix(self: *File, ctx: Context, name: []const u8) ![]const u8 {
    if (ctx.family != .function or ctx.inner == null) return self.say("Split '{s}' so each part makes fewer decisions, or replace a chain of branches with a table.", .{name});
    var body: Body = .{};
    listStatements(self, ctx, &body);
    const decision = self.v.decision_point orelse return self.say("Split '{s}' so each part makes fewer decisions, or replace a chain of branches with a table.", .{name});
    var busiest: ?ts.Node = null;
    var most: u32 = 0;
    for (body.statements[0..body.count]) |statement| {
        const count = capturesIn(self, statement, decision);
        if (count <= most) continue;
        busiest = statement;
        most = count;
    }
    const step = busiest orelse return self.say("Split '{s}' so each part makes fewer decisions, or replace a chain of branches with a table.", .{name});
    const first = ts.ts_node_start_point(step).row + 1;
    const last = ts.ts_node_end_point(step).row + 1;
    if (last < first) assert.panic("{s}: a step of '{s}' ends on line {d}, before it starts on {d}", .{ self.work.facts.path, name, last, first });
    if (name.len == 0) assert.panic("{s}: advising how to split an unnamed function; closeFunction() returns before unnamed ones", .{self.work.facts.path});
    return self.say("Lines {d}-{d}, starting `{s}`, make {d} of its {d} decisions; move them into a function of their own, or replace a chain of branches there with a table.", .{ first, last, header(step.text(self.source)), @min(most, ctx.decisions), ctx.decisions });
}

/// How many captures with `id` lie inside `node`.
pub fn capturesIn(self: *File, node: ts.Node, id: captures.Id) u32 {
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    if (end > self.source.len) assert.panic("{s}: {f} ends past the {d}-byte file; pass a node from this file", .{ self.work.facts.path, node.where(), self.source.len });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, hazards.startsBefore);
    var count: u32 = 0;
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        count += @intFromBool(t.id == id);
    }
    if (count > end - start) assert.panic("{s}: counted {d} captures in {d} bytes; each capture starts at its own byte or later", .{ self.work.facts.path, count, end - start });
    return count;
}

/// The body's top-level statements, and for each name which of them set it and which read it.
/// False when the body is too short to hold a block worth moving.
fn readBody(self: *File, ctx: Context, body: *Body) bool {
    listStatements(self, ctx, body);
    if (body.count < 2 * rules.min_extract_statements) return false;
    const start = ts.ts_node_start_byte(body.statements[0]);
    const end = ts.ts_node_end_byte(body.statements[body.count - 1]);
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, hazards.startsBefore);
    body.ids = FlowIds.forQuery(self.checker.compiled);
    const ids = body.ids;
    if (first > self.index.triples.len) assert.panic("{s}: the body's captures start at {d}, past the {d} recorded; lowerBound searches within them", .{ self.work.facts.path, first, self.index.triples.len });
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        const at = body.statementAt(t.key.start) orelse continue;
        if (t.id == ids.exit) {
            if (escapes(self, t.node, body.statements[at], ids.loop)) body.exits |= @as(Mask, 1) << @intCast(at);
        } else trackName(self, body, t, at);
    }
    const signature = self.s.signature.items();
    for (signature[ctx.parameter_start..][0..ctx.parameter_count]) |p| {
        if (body.nameFor(p.name.text(self.source))) |n| n.parameter = true;
    }
    if (body.name_count > max_names) assert.panic("{s}: tracked {d} names in room for {d}; nameFor() must refuse more", .{ self.work.facts.path, body.name_count, max_names });
    return true;
}

const FlowIds = struct {
    write: ?captures.Id,
    declare: ?captures.Id,
    read: ?captures.Id,
    exit: ?captures.Id,
    loop: ?captures.Id,

    fn forQuery(c: captures.Compiled) FlowIds {
        const ids: FlowIds = .{ .write = c.id("write.target"), .declare = c.id("local.definition.var"), .read = c.id("local.reference"), .exit = c.id("flow.exit"), .loop = c.id("loop.outer") };
        if (ids.read == null) assert.panic("extractable-block runs on a language whose queries have no @local.reference; the language test should have caught this", .{});
        if (ids.write != null and ids.write == ids.read) assert.panic("@write.target and @local.reference share id {d}; each capture name has its own", .{ids.write.?});
        return ids;
    }
};

/// Notes in `body` that statement `at` declares, sets, changes or reads the name the capture starts with.
fn trackName(self: *File, body: *Body, t: captures.Triple, at: usize) void {
    const ids = body.ids;
    if (t.node.id == null) assert.panic("{s}: a capture at byte {d} has no node; index() records only real nodes", .{ self.work.facts.path, t.key.start });
    if (at >= body.count) assert.panic("{s}: a name in statement {d} of {d}; statementAt() returns only statements of the body", .{ self.work.facts.path, at, body.count });
    if (t.id != ids.write and t.id != ids.declare and t.id != ids.read) return;
    const whole = t.node.text(self.source);
    const text = rootOf(whole);
    if (std.mem.trim(u8, text, "_").len == 0 or check.contains(self.tables.self_receivers, text)) return;
    const n = body.nameFor(text) orelse return;
    const bit = @as(Mask, 1) << @intCast(at);
    if (t.id == ids.declare) {
        n.declared |= bit;
        n.assigned |= bit;
    } else if (t.id == ids.write) {
        if (text.len == whole.len) n.assigned |= bit else n.touched |= bit;
    } else n.read |= bit;
}

/// The body's top-level statements: the children of the block its @inner starts, or of the one
/// list a grammar wraps them in, as Go's statement_list does.
fn listStatements(self: *File, ctx: Context, body: *Body) void {
    if (body.count != 0) assert.panic("{s}: listing the statements of {f} into a body that already holds {d}; list them once", .{ self.work.facts.path, ctx.node.where(), body.count });
    body.count = topStatements(self, ctx, &body.statements);
    if (body.count > max_statements) assert.panic("{s}: listed {d} statements in room for {d}; topStatements() fills at most its buffer", .{ self.work.facts.path, body.count, max_statements });
}

/// The top-level statements of `ctx`'s body, in order, up to `out.len` of them.
pub fn topStatements(self: *File, ctx: Context, out: []ts.Node) usize {
    var container = ctx.inner orelse assert.panic("{s}: listing the statements of {f}, which has no body; skip constructs without one", .{ self.work.facts.path, ctx.node.where() });
    if (self.parentOf(container)) |parent| if (!parent.eql(ctx.node) and !parent.eql(ctx.span)) {
        container = parent;
    };
    if (ts.ts_node_end_byte(container) > ts.ts_node_end_byte(ctx.span)) assert.panic("{s}: the body {f} ends after its construct {f}; @inner must be inside @outer", .{ self.work.facts.path, container.where(), ctx.span.where() });
    for (0..4) |_| {
        if (ts.ts_node_named_child_count(container) != 1) break;
        container = ts.ts_node_named_child(container, 0);
    }
    var count: usize = 0;
    for (0..ts.ts_node_named_child_count(container)) |i| {
        const child = ts.ts_node_named_child(container, @intCast(i));
        if (ts.ts_node_is_extra(child)) continue;
        if (count == out.len) break;
        out[count] = child;
        count += 1;
    }
    if (count > out.len) assert.panic("{s}: listed {d} statements in room for {d}; the loop stops when full", .{ self.work.facts.path, count, out.len });
    return count;
}

/// The name an assignment or read starts with: `self` for `self.total`.
fn rootOf(text: []const u8) []const u8 {
    if (text.len == 0) assert.panic("asked for the name an empty capture starts with; captures match nodes with text", .{});
    const end = std.mem.indexOfNone(u8, text, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$@") orelse text.len;
    if (end > text.len) assert.panic("the name in '{s}' ends at {d}, past its end; rootOf() must slice within it", .{ text, end });
    return text[0..end];
}

/// Whether `exit` leaves its top-level statement: a return always does, a break or continue does
/// unless a loop inside that statement holds it.
fn escapes(self: *File, exit: ts.Node, statement: ts.Node, loop: ?captures.Id) bool {
    if (ts.ts_node_end_byte(exit) > ts.ts_node_end_byte(statement)) assert.panic("{s}: the exit {f} ends after its statement {f}; statementAt() must place it inside", .{ self.work.facts.path, exit.where(), statement.where() });
    if (std.mem.startsWith(u8, exit.text(self.source), "return")) return true;
    const from = ts.ts_node_start_byte(statement);
    const at = ts.ts_node_start_byte(exit);
    if (at < from) assert.panic("{s}: the exit {f} starts before its statement {f}; statementAt() must place it inside", .{ self.work.facts.path, exit.where(), statement.where() });
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, from, hazards.startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start > at) break;
        if (t.id == loop and ts.ts_node_end_byte(t.node) >= ts.ts_node_end_byte(exit)) return false;
    }
    return true;
}

/// The longest run of statements leaving at least `rules.min_extract_statements` behind, with no exit, at most one name read after
/// it and at most `rules.max_parameters` read from before it.
fn best(body: *const Body) ?Window {
    if (body.count < 2 * rules.min_extract_statements) assert.panic("searching a body of {d} statements; readBody() rejects bodies under twice the block minimum", .{body.count});
    var found: ?Window = null;
    for (0..body.count) |start| {
        var end = start + rules.min_extract_statements;
        while (end <= body.count and end - start + rules.min_extract_statements <= body.count) : (end += 1) {
            const window = fits(body, start, end) orelse continue;
            if (found == null or end - start > found.?.end - found.?.start) found = window;
        }
    }
    if (found) |w| if (w.end - w.start < rules.min_extract_statements) assert.panic("chose a block of {d} statements, under the {d} required; best() must start windows at the minimum", .{ w.end - w.start, rules.min_extract_statements });
    return found;
}

fn fits(body: *const Body, start: usize, end: usize) ?Window {
    if (end > body.count or start >= end) assert.panic("checking statements {d}..{d} of {d}; best() must keep windows inside the body", .{ start, end, body.count });
    if (body.count > max_statements) assert.panic("a body of {d} statements in room for {d}; listStatements() stops at max_statements", .{ body.count, max_statements });
    const inside: Mask = (if (end == max_statements) ~@as(Mask, 0) else (@as(Mask, 1) << @intCast(end)) - 1) & ~((@as(Mask, 1) << @intCast(start)) - 1);
    if (body.exits & inside != 0) return null;
    const before: Mask = (@as(Mask, 1) << @intCast(start)) - 1;
    const after = ~(before | inside);
    var window: Window = .{ .start = start, .end = end };
    for (body.names[0..body.name_count]) |*n| {
        if (!n.parameter and n.assigned & inside != 0 and firstOf(n.read & after) < firstOf(n.declared & after)) {
            if (window.output != null) return null;
            window.output = n;
        }
        const used = (n.read | n.touched) & inside;
        if (used == 0 or firstOf(n.declared & inside) <= firstOf(used)) continue;
        if (!n.parameter and (n.assigned | n.touched) & before == 0) continue;
        if (window.input_count == window.inputs.len) return null;
        window.inputs[window.input_count] = n;
        window.input_count += 1;
    }
    return window;
}

/// The first statement in `mask`, or past the last there can be when it is empty.
fn firstOf(mask: Mask) usize {
    const first: usize = @ctz(mask);
    if (first > max_statements) assert.panic("the first statement of a mask came out as {d}, past {d}; @ctz of a {d}-bit mask is at most its width", .{ first, max_statements, max_statements });
    if (mask != 0 and mask & (@as(Mask, 1) << @intCast(first)) == 0) assert.panic("statement {d} was taken as the first in a mask without it; firstOf() must return a set bit", .{first});
    return first;
}
