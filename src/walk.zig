//! The walk over a file's syntax tree: entering each node opens the constructs its captures
//! mark, records the parts captured inside them, and leaving it closes them.
const std = @import("std");
const closing = @import("closing.zig");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const messages = @import("messages.zig");
const hazards = @import("hazards.zig");
const types = @import("types.zig");
const test_quality = @import("test_quality.zig");
const isolation = @import("isolation.zig");
const notes = @import("notes.zig");
const check = @import("check.zig");
const Family = check.Family;
pub const Summary = check.Summary;
const Context = check.Context;
const File = check.File;

pub fn walk(self: *File, root: ts.Node) !void {
    if (self.s.contexts.len != 0) assert.panic("{s}: starting a walk with {d} constructs already open; clear the scratch first", .{ self.work.facts.path, self.s.contexts.len });
    if (self.s.opened.len != 0) assert.panic("{s}: starting a walk with {d} nodes already open; clear the scratch first", .{ self.work.facts.path, self.s.opened.len });
    var cursor = ts.ts_tree_cursor_new(root);
    defer ts.ts_tree_cursor_delete(&cursor);
    try enter(self, ts.ts_tree_cursor_current_node(&cursor));
    const steps = 2 * @as(usize, ts.ts_node_descendant_count(root)) + 1;
    var descending = true;
    for (0..steps) |_| {
        if (descending and ts.ts_tree_cursor_goto_first_child(&cursor)) {
            try enter(self, ts.ts_tree_cursor_current_node(&cursor));
            continue;
        }
        try leave(self);
        if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) {
            try enter(self, ts.ts_tree_cursor_current_node(&cursor));
            descending = true;
            continue;
        }
        if (!ts.ts_tree_cursor_goto_parent(&cursor)) return;
        descending = false;
    }
    return error.TreeWalkExceededNodeCount;
}

pub fn enter(self: *File, node: ts.Node) !void {
    try self.s.path.add(node);
    const found = self.index.ofNext(&self.next_capture, node);
    const depth = self.s.contexts.len;
    for (found) |t| {
        if (t.id >= self.checker.compiled.captureCount()) assert.panic("{s}: {f} carries capture id {d}, but the query has {d} captures; build the capture index with this checker's compiled query", .{ self.work.facts.path, node.where(), t.id, self.checker.compiled.captureCount() });
        if (!try enterSignal(self, node, t.id, found)) try enterCapture(self, node, self.checker.compiled.names[t.id]);
    }
    const opened = try openFamilies(self, node, found);
    if (self.s.contexts.len != depth + opened) assert.panic("{s}: entering {f} opened {d} constructs but the stack grew from {d} to {d}; only openFamilies() may open constructs, so check enterSignal() and enterCapture()", .{ self.work.facts.path, node.where(), opened, depth, self.s.contexts.len });
    try self.s.opened.add(opened);
}

/// Captures that mark something about the node on their own, such as a decision point or an
/// error message. Returns whether `id` was one of them.
pub fn enterSignal(self: *File, node: ts.Node, id: captures.Id, found: []const captures.Triple) !bool {
    if (found.len == 0) assert.panic("{s}: {f} carries capture {d} but no captures were found on it; call enterSignal() only with captures found on this node", .{ self.work.facts.path, node.where(), id });
    if (try notes.note(self, node, id)) return true;
    const v = self.v;
    if (v.catch_swallowed == id) {
        _ = try self.report(node, "swallowed-error", try self.say("This error handler does nothing, so the failure disappears silently.", .{}));
        return false;
    }
    if (v.decision_point == id) {
        if (!hasOuter(self, found, .assertion)) if (self.enclosingUnit()) |unit| {
            unit.decisions += 1;
        };
    } else if (v.test_shared_state == id) {
        try isolation.checkSharedStatement(self, node);
    } else if (v.test_constant == id) {
        try test_quality.checkConstantCheck(self, node);
    } else if (v.test_check == id) {
        if (test_quality.enclosingTest(self)) |unit| unit.checks += 1;
    } else if (v.async_name == id) {
        try self.s.async_names.add(node.text(self.source));
    } else if (v.statement_call == id) {
        try self.s.statement_calls.add(node);
    } else if (v.error_message == id) {
        if (self.innermost(.assertion) == null) try messages.checkMessage(self, node, null);
    } else return false;
    if (self.s.statement_calls.len > self.s.statement_calls.capacity()) assert.panic("{s}: {d} statement calls in room for {d}; raise memory.Limits.per_file, or split the file", .{ self.work.facts.path, self.s.statement_calls.len, self.s.statement_calls.capacity() });
    return true;
}

/// Captures that fill in part of an open construct: its name, a parameter, a local, a condition.
pub fn enterCapture(self: *File, node: ts.Node, name: captures.Name) !void {
    if (name.full.len == 0) assert.panic("{s}: {f} carries a capture with no name; name every capture in the language's .scm files, such as @call.name", .{ self.work.facts.path, node.where() });
    if (std.mem.eql(u8, name.family, "finding")) return hazards.patternFinding(self, node, name.part);
    if (std.mem.eql(u8, name.full, "name")) {
        if (self.innermost(.definition)) |definition| {
            if (definition.name == null) definition.name = node;
        }
        return;
    }
    if (std.mem.eql(u8, name.part, "outer")) return;
    if (std.mem.eql(u8, name.family, "parameter")) return parameter(self, name.part, node);
    if (std.mem.eql(u8, name.family, "type")) return types.capture(self, name.part, node);
    if (std.mem.eql(u8, name.family, "local.definition") and (std.mem.eql(u8, name.part, "var") or std.mem.eql(u8, name.part, "parameter"))) {
        if (self.innermost(.function)) |function| try self.s.locals.add(.{ .owner = function.serial, .text = node.text(self.source) });
        if (std.mem.eql(u8, name.part, "parameter")) try parameter(self, "name", node);
        return;
    }
    const family = std.meta.stringToEnum(Family, name.family) orelse return;
    const ctx = self.innermost(family) orelse return;
    try assign(self, ctx, name.part, node);
    if (ctx.family != family) assert.panic("{s}: {f} was assigned to a {t} while looking for a {t}; innermost() must return a context of the family it was asked for", .{ self.work.facts.path, node.where(), ctx.family, family });
}

/// Opens a construct for each family the node is the outer node of; returns how many.
pub fn openFamilies(self: *File, node: ts.Node, found: []const captures.Triple) !u8 {
    const before = self.s.contexts.len;
    if (before > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, before, self.s.contexts.capacity() });
    var opened: u8 = 0;
    for (std.enums.values(Family)) |family| {
        if (!hasOuter(self, found, family)) continue;
        if (refines(self, family, node, found)) |merged| {
            merged.span = node;
        } else {
            try open(self, family, node);
            opened += 1;
        }
    }
    if (definitionKind(self, found)) |kind| {
        try open(self, .definition, node);
        self.s.contexts.last().?.kind = kind;
        opened += 1;
    }
    if (self.s.contexts.len != before + opened) assert.panic("{s}: opened {d} constructs at {f} but the stack grew by {d}; openFamilies() must count each open(), and nothing else may add contexts", .{ self.work.facts.path, opened, node.where(), self.s.contexts.len - before });
    return opened;
}

pub fn definitionKind(self: *File, found: []const captures.Triple) ?[]const u8 {
    const names = self.checker.compiled.names;
    if (found.len > self.index.triples.len) assert.panic("{s}: {d} captures on one node, more than the {d} in the file; of() must slice within the recorded captures", .{ self.work.facts.path, found.len, self.index.triples.len });
    for (found) |t| {
        if (!std.mem.eql(u8, names[t.id].family, "definition")) continue;
        if (names[t.id].part.len == 0) assert.panic("capture @{s} has no kind after 'definition.'; write it as @definition.function, @definition.class and so on", .{names[t.id].full});
        return names[t.id].part;
    }
    return null;
}

pub fn hasOuter(self: *File, found: []const captures.Triple, family: Family) bool {
    const names = self.checker.compiled.names;
    if (found.len > self.index.triples.len) assert.panic("{s}: {d} captures on one node, more than the {d} in the file; of() must slice within the recorded captures", .{ self.work.facts.path, found.len, self.index.triples.len });
    for (found) |t| {
        if (t.id >= names.len) assert.panic("{s}: capture id {d} is out of range; the query has {d} captures", .{ self.work.facts.path, t.id, names.len });
        if (std.mem.eql(u8, names[t.id].part, "outer") and std.mem.eql(u8, names[t.id].family, @tagName(family))) return true;
    }
    return false;
}

pub fn leave(self: *File) !void {
    const opened = self.s.opened.drop() orelse return error.LeftMoreNodesThanEntered;
    if (opened > self.s.contexts.len) assert.panic("{s}: leaving a node that opened {d} constructs, but only {d} are open; only leave() may drop contexts, so check what closed them early", .{ self.work.facts.path, opened, self.s.contexts.len });
    const remaining = self.s.contexts.len - opened;
    for (0..opened) |_| {
        const ctx = self.s.contexts.drop().?;
        try closing.close(self, ctx);
    }
    if (self.s.contexts.len != remaining) assert.panic("{s}: closing constructs left {d} open, expected {d}; close() must not open or drop contexts itself", .{ self.work.facts.path, self.s.contexts.len, remaining });
    if (self.s.path.drop() == null) assert.panic("{s}: left a node, but the walk's path is empty; enter() must add each node it enters to the path", .{self.work.facts.path});
}

pub fn parameter(self: *File, part: []const u8, node: ts.Node) !void {
    if (part.len == 0) assert.panic("{s}: {f} is captured as a parameter with no part; write @parameter.name or @parameter.type", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) <= ts.ts_node_start_byte(node)) assert.panic("{s}: parameter capture @parameter.{s} matched the empty {f}; capture a named node", .{ self.work.facts.path, part, node.where() });
    const function = self.innermost(.function) orelse return;
    if (std.mem.eql(u8, part, "name")) {
        const last = if (function.parameter_count > 0) self.s.signature.last() else null;
        if (last != null and last.?.name.eql(node)) return;
        try self.s.signature.add(.{ .name = node });
        function.parameter_count += 1;
    } else if (std.mem.eql(u8, part, "type")) {
        if (function.parameter_count > 0) self.s.signature.last().?.type = node;
    }
}

pub fn assign(self: *File, ctx: *Context, part: []const u8, node: ts.Node) !void {
    if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(ctx.node)) assert.panic("{s}: @{t}.{s} captured {f}, which starts before its @{t}.outer {f}; the query must capture parts inside the outer node", .{ self.work.facts.path, ctx.family, part, node.where(), ctx.family, ctx.node.where() });
    if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: @{t}.{s} captured {f}, which ends after its @{t}.outer {f}; the query must capture parts inside the outer node", .{ self.work.facts.path, ctx.family, part, node.where(), ctx.family, ctx.node.where() });
    const slots = .{ "name", "callee", "receiver", "condition", "message", "iterable", "lhs", "rhs" };
    inline for (slots) |slot| {
        if (std.mem.eql(u8, part, slot)) {
            if (@field(ctx, slot) == null) @field(ctx, slot) = node;
            if (ctx.family == .function and std.mem.eql(u8, slot, "name")) {
                ctx.is_test = self.isTestName(node.text(self.source));
                const at = ts.ts_node_start_point(node);
                ctx.fact = try self.work.facts.function(node.text(self.source), .{ at.row, at.column }, self.definedInClass());
            }
            return;
        }
    }
    if (std.mem.eql(u8, part, "inner")) {
        if (!ctx.body) {
            ctx.body_start = ts.ts_node_start_byte(node);
            ctx.inner = node;
        }
        ctx.body = true;
    } else if (std.mem.eql(u8, part, "argument")) {
        if (ctx.argument_count < ctx.arguments.len) ctx.arguments[ctx.argument_count] = node;
        ctx.argument_count += 1;
    } else if (std.mem.eql(u8, part, "parameter")) {
        ctx.formal_parameters += 1;
    }
}

pub fn refines(self: *File, family: Family, node: ts.Node, found: []const captures.Triple) ?*Context {
    if (found.len == 0) assert.panic("{s}: asked whether {f} refines a {t} with no captures on it; call refines() only from openFamilies(), with the node's captures", .{ self.work.facts.path, node.where(), family });
    for (found) |t| {
        const name = self.checker.compiled.names[t.id];
        if (!std.mem.eql(u8, name.family, @tagName(family))) continue;
        if (std.mem.eql(u8, name.part, "outer") or std.mem.eql(u8, name.part, "passthrough")) continue;
        return null;
    }
    const parent = self.parentOf(node) orelse return null;
    const items = self.s.contexts.items();
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const ctx = &items[i];
        if (!ctx.span.eql(parent) and !ctx.node.eql(parent)) return null;
        if (ctx.family != family) continue;
        if (ctx.body) return null;
        if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: {f} refines the {t} {f} but ends after it; capture the refining node inside the construct's @outer in the language's zanity.scm", .{ self.work.facts.path, node.where(), family, ctx.node.where() });
        return ctx;
    }
    if (i != 0) assert.panic("{s}: the search for a {t} to refine stopped at depth {d} without returning; the loop in refines() must return from inside, so check its exits", .{ self.work.facts.path, family, i });
    return null;
}

pub fn open(self: *File, family: Family, node: ts.Node) !void {
    if (self.s.contexts.last()) |top| {
        if (ts.ts_node_start_byte(node) < ts.ts_node_start_byte(top.node)) assert.panic("{s}: opening a {t} at {f}, which starts before the enclosing {t} {f}; the walk visits nodes in order", .{ self.work.facts.path, family, node.where(), top.family, top.node.where() });
        if (ts.ts_node_end_byte(node) > ts.ts_node_end_byte(top.node)) assert.panic("{s}: opening a {t} at {f}, which ends after the enclosing {t} {f}; capture the inner construct inside the outer one's node in the language's zanity.scm", .{ self.work.facts.path, family, node.where(), top.family, top.node.where() });
    }
    self.serials += 1;
    var ctx: Context = .{
        .family = family,
        .node = node,
        .span = node,
        .serial = self.serials,
        .is_test = family == .@"test",
        .parameter_start = self.s.signature.len,
        .owned_start = @min(self.s.locals.len, self.s.bare_calls.len),
        .trail_mark = self.s.trail.len,
        .repeat_mark = self.s.repeats.len,
    };
    switch (family) {
        .assertion => {
            if (self.enclosingFunction()) |function| function.asserts += 1;
            if (test_quality.enclosingTest(self)) |unit| unit.checks += 1;
        },
        .statement => if (self.parentOf(node)) |parent| {
            ctx.previous = trailFor(self, parent.key());
        },
        .control => {
            ctx.chained = self.index.marks(node, self.v.control_chain);
            try hazards.checkNesting(self, node, ctx.chained);
        },
        else => {},
    }
    try self.s.contexts.add(ctx);
}

pub fn trailFor(self: *File, parent: ts.Node.Key) Summary {
    const trail = self.s.trail.items();
    if (trail.len > self.s.trail.capacity()) assert.panic("{s}: {d} statement summaries in room for {d}; raise memory.Limits.depth, or check that remember() trims the trail", .{ self.work.facts.path, trail.len, self.s.trail.capacity() });
    var i = trail.len;
    while (i > 0) {
        i -= 1;
        const entry = trail[i];
        if (entry.parent.id == parent.id and entry.parent.start == parent.start) return entry.summary;
    }
    if (i != 0) assert.panic("{s}: the search for the previous statement stopped at {d} without returning; the loop in trailFor() must return from inside, so check its exits", .{ self.work.facts.path, i });
    return .none;
}
