//! The weak-assertion checks (NASA05-M1 to M5): assertions that restate a type annotation,
//! repeat a constant just assigned, check a conversion that can't fail, or bound a length that
//! can't be negative. Each is counted out of the function's assertion density.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const sameText = check.sameText;
const Call = check.Call;
const Assertion = check.Assertion;
const Note = check.Note;
const suppress = @import("suppress.zig");

pub fn restatedType(self: *File, function: *Context, node: ts.Node, condition: ts.Node) !void {
    if (function.family != .function) assert.panic("{s}: checking restated types against the {t} {f}, which is not a function; call restatedType() only with the enclosing function's context", .{ self.work.facts.path, function.family, function.node.where() });
    if (ts.ts_node_start_byte(condition) < ts.ts_node_start_byte(node)) assert.panic("{s}: the condition {f} starts before its assertion {f}; capture @assertion.condition inside @assertion.outer in the language's zanity.scm", .{ self.work.facts.path, condition.where(), node.where() });
    const call = typeCheck(self, condition) orelse return;
    const subject = call.arguments[0].?.text(self.source);
    const type_text = call.arguments[1].?.text(self.source);
    const params = self.s.signature.items()[function.parameter_start..][0..function.parameter_count];
    for (params) |p| {
        if (!std.mem.eql(u8, p.name.text(self.source), subject)) continue;
        const annotation = p.type orelse return;
        if (!annotationIs(self, annotation.text(self.source), type_text)) return;
        try weak(self, function, .{ .node = node, .rule = "restated-type", .message = try self.say("This assertion only repeats that '{s}' is a {s}, which its annotation already guarantees.", .{ subject, type_text }) });
        return;
    }
}

pub fn annotationIs(self: *File, annotation: []const u8, type_text: []const u8) bool {
    if (annotation.len == 0) assert.panic("{s}: comparing '{s}' with an empty type annotation; @parameter.type matched an empty node", .{ self.work.facts.path, type_text });
    if (type_text.len == 0) assert.panic("{s}: comparing annotation '{s}' with an empty type; the type check's second argument is empty", .{ self.work.facts.path, annotation });
    var matched = false;
    var depth: usize = 0;
    var start: usize = 0;
    for (0..annotation.len + 1) |i| {
        if (i < annotation.len) {
            switch (annotation[i]) {
                '[', '(', '{' => depth += 1,
                ']', ')', '}' => depth -|= 1,
                else => {},
            }
            if (annotation[i] != '|' or depth != 0) continue;
        }
        const part = std.mem.trim(u8, annotation[start..i], " \t");
        start = i + 1;
        if (contains(self.tables.null_types, part)) continue;
        if (matched or !sameText(part, type_text)) return false;
        matched = true;
    }
    return matched;
}

pub fn callFor(self: *File, node: ts.Node) ?Call {
    const key = node.key();
    const calls = self.s.calls.items();
    if (calls.len > self.s.calls.capacity()) assert.panic("{s}: {d} calls recorded in room for {d}; raise memory.Limits.captures", .{ self.work.facts.path, calls.len, self.s.calls.capacity() });
    var i = calls.len;
    while (i > 0) {
        i -= 1;
        const call = calls[i];
        if (call.key.id == key.id and call.key.start == key.start) return call;
    }
    if (i != 0) assert.panic("{s}: the search for the call at {f} stopped at {d} without returning; the loop in callFor() must return from inside, so check its exits", .{ self.work.facts.path, node.where(), i });
    return null;
}

pub fn typeCheck(self: *File, node: ts.Node) ?Call {
    const call = callFor(self, node) orelse return null;
    const name = call.name orelse return null;
    if (call.receiver or call.count != 2) return null;
    if (!contains(self.tables.type_checks, name.text(self.source))) return null;
    if (call.arguments[0] == null or call.arguments[1] == null) assert.panic("{s}: the type check {f} counts 2 arguments but did not record both; check @call.argument", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(call.arguments[0].?) > ts.ts_node_start_byte(call.arguments[1].?)) assert.panic("{s}: the arguments of {f} overlap ({f} and {f}); @call.argument captured nested nodes", .{ self.work.facts.path, node.where(), call.arguments[0].?.where(), call.arguments[1].?.where() });
    return call;
}

pub fn plainCall(self: *File, node: ts.Node, table: []const []const u8) ?[]const u8 {
    const call = callFor(self, node) orelse return null;
    const name = call.name orelse return null;
    if (call.receiver) return null;
    const text = name.text(self.source);
    if (text.len == 0) assert.panic("{s}: the call {f} has an empty name; @call.name matched an empty node, so capture the callee's identifier as @call.name in the language's zanity.scm", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_start_byte(name) < ts.ts_node_start_byte(node)) assert.panic("{s}: @call.name {f} starts before its call {f}; capture @call.name inside @call.outer in the language's zanity.scm", .{ self.work.facts.path, name.where(), node.where() });
    return if (contains(table, text)) text else null;
}

pub fn afterAssignment(self: *File, here: Assertion, lhs: ts.Node, rhs: ts.Node) !void {
    const function = here.function;
    const node = here.node;
    const condition = here.condition;
    if (ts.ts_node_end_byte(rhs) > ts.ts_node_start_byte(node)) assert.panic("{s}: the assignment value {f} ends after the assertion {f} that follows it; pass nodes from the tree parsed from this file, since tree-sitter nests a node inside its parent", .{ self.work.facts.path, rhs.where(), node.where() });
    if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(rhs)) assert.panic("{s}: @assignment.lhs {f} overlaps @assignment.rhs {f}; the query captured the wrong nodes", .{ self.work.facts.path, lhs.where(), rhs.where() });
    const target = lhs.text(self.source);
    if (isLiteral(self, rhs) and alwaysHolds(self, condition, target, rhs)) {
        try weak(self, function, .{ .node = node, .rule = "constant-assertion", .message = try self.say("This assertion can never fail: '{s}' was just set to a constant.", .{target}) });
    }
    const total = self.index.marks(rhs, self.v.string_format) or plainCall(self, rhs, self.tables.total_conversions) != null;
    if (total and isPath(self, condition, target)) {
        try weak(self, function, .{ .node = node, .rule = "conversion-assertion", .message = try self.say("'{s}' comes from a conversion that always produces a value, so this assertion can't catch a bug.", .{target}) });
    }
    if (plainCall(self, rhs, self.tables.length_calls)) |length| {
        if (self.index.marks(condition, self.v.compare_non_negative) and subjectIs(self, condition, target)) {
            try weak(self, function, .{ .node = node, .rule = "guaranteed-length", .message = try self.say("'{s}' comes from {s}(), which is never negative, so this can't fail.", .{ target, length }) });
        }
    }
}

pub fn afterAssertion(self: *File, here: Assertion, previous: ts.Node, previous_condition: ts.Node) !void {
    const function = here.function;
    const condition = here.condition;
    if (ts.ts_node_end_byte(previous) > ts.ts_node_start_byte(condition)) assert.panic("{s}: the previous assertion {f} ends after this condition {f} starts; pass nodes from the tree parsed from this file, since tree-sitter nests a node inside its parent", .{ self.work.facts.path, previous.where(), condition.where() });
    if (ts.ts_node_start_byte(previous_condition) < ts.ts_node_start_byte(previous)) assert.panic("{s}: the condition {f} starts before its assertion {f}; capture @assertion.condition inside @assertion.outer in the language's zanity.scm", .{ self.work.facts.path, previous_condition.where(), previous.where() });
    if (!self.index.marks(previous_condition, self.v.compare_not_null)) return;
    const subject = childWith(self, previous_condition, self.v.compare_subject) orelse return;
    const call = typeCheck(self, condition) orelse return;
    if (!sameText(call.arguments[0].?.text(self.source), subject.text(self.source))) return;
    const null_name = if (self.tables.null_types.len > 0) self.tables.null_types[0] else "missing";
    try weak(self, function, .{ .node = previous, .rule = "redundant-null-check", .message = try self.say("Checking that '{s}' is not {s} is redundant: the {s} on the next line already rules it out.", .{ subject.text(self.source), null_name, call.name.?.text(self.source) }) });
}

pub fn isPath(self: *File, node: ts.Node, target: []const u8) bool {
    if (target.len == 0) assert.panic("{s}: asked whether {f} is the empty name; the assigned name is never empty", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: {f} ends at byte {d}, past the {d}-byte file; pass a node from the tree parsed from this file", .{ self.work.facts.path, node.where(), ts.ts_node_end_byte(node), self.source.len });
    return self.index.marks(node, self.v.expression_path) and sameText(node.text(self.source), target);
}

pub fn isLiteral(self: *File, node: ts.Node) bool {
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: {f} ends at byte {d}, past the {d}-byte file; pass a node from the tree parsed from this file", .{ self.work.facts.path, node.where(), ts.ts_node_end_byte(node), self.source.len });
    if (ts.ts_node_start_byte(node) > ts.ts_node_end_byte(node)) assert.panic("{s}: {f} runs backwards; pass a node from a live tree parsed from this file", .{ self.work.facts.path, node.where() });
    if (self.index.marks(node, self.v.literal_collection)) return true;
    if (self.index.marks(node, self.v.literal_constant) and !self.index.marks(node, self.v.string_format)) return true;
    return plainCall(self, node, self.tables.constant_constructors) != null;
}

pub fn alwaysHolds(self: *File, condition: ts.Node, target: []const u8, value: ts.Node) bool {
    if (target.len == 0) assert.panic("{s}: asked whether {f} always holds for an empty name; skip empty names before calling alwaysHolds()", .{ self.work.facts.path, condition.where() });
    if (ts.ts_node_end_byte(value) > ts.ts_node_start_byte(condition)) assert.panic("{s}: the assigned value {f} ends after the condition {f} starts; pass nodes from the tree parsed from this file, since tree-sitter nests a node inside its parent", .{ self.work.facts.path, value.where(), condition.where() });
    if (isPath(self, condition, target)) {
        return self.index.marks(value, self.v.literal_constant) and
            !self.index.marks(value, self.v.literal_falsy) and
            !self.index.marks(value, self.v.string_format);
    }
    if (self.index.marks(condition, self.v.compare_not_null) and subjectIs(self, condition, target)) {
        return !self.index.marks(value, self.v.literal_none);
    }
    if (self.index.marks(condition, self.v.compare_equal) and subjectIs(self, condition, target)) {
        const compared = childWith(self, condition, self.v.compare_value) orelse return false;
        return sameText(compared.text(self.source), value.text(self.source));
    }
    return false;
}

pub fn subjectIs(self: *File, condition: ts.Node, target: []const u8) bool {
    if (target.len == 0) assert.panic("{s}: asked whether {f} compares an empty name; skip empty names before calling subjectIs()", .{ self.work.facts.path, condition.where() });
    const subject = childWith(self, condition, self.v.compare_subject) orelse return false;
    if (ts.ts_node_start_byte(subject) < ts.ts_node_start_byte(condition)) assert.panic("{s}: @compare.subject {f} starts before its comparison {f}; capture @compare.subject inside the comparison in the language's zanity.scm", .{ self.work.facts.path, subject.where(), condition.where() });
    return sameText(subject.text(self.source), target);
}

pub fn childWith(self: *File, node: ts.Node, capture: ?captures.Id) ?ts.Node {
    const count = ts.ts_node_named_child_count(node);
    if (count > ts.ts_node_descendant_count(node)) assert.panic("{s}: {f} has {d} named children but {d} descendants; pass a node from a live tree, since tree-sitter never counts fewer descendants than children", .{ self.work.facts.path, node.where(), count, ts.ts_node_descendant_count(node) });
    for (0..count) |i| {
        const child = ts.ts_node_named_child(node, @intCast(i));
        if (self.index.marks(child, capture)) {
            if (ts.ts_node_end_byte(child) > ts.ts_node_end_byte(node)) assert.panic("{s}: the child {f} ends after its parent {f}; pass a node from a live tree parsed from this file", .{ self.work.facts.path, child.where(), node.where() });
            return child;
        }
    }
    return null;
}

pub fn weak(self: *File, function: *Context, finding: Note) !void {
    if (function.family != .function) assert.panic("{s}: recording a weak assertion against the {t} {f}, which is not a function; call weak() only with the enclosing function's context", .{ self.work.facts.path, function.family, function.node.where() });
    if (ts.ts_node_start_byte(finding.node) < ts.ts_node_start_byte(function.node)) assert.panic("{s}: the weak assertion {f} ({s}) starts before its function {f}; record only assertions inside the function", .{ self.work.facts.path, finding.node.where(), finding.rule, function.node.where() });
    if (!try self.report(finding.node, finding.rule, finding.message)) return;
    const line = ts.ts_node_start_point(finding.node).row;
    for (self.s.weak.items()) |w| if (w.owner == function.serial and w.line == line) return;
    try self.s.weak.add(.{ .owner = function.serial, .line = line });
}

/// Points at what is worth asserting in this function, its inputs and its
/// result, rather than asking for any assertion that makes up the count.
pub fn assertionFix(self: *File, ctx: Context, name: []const u8) ![]const u8 {
    if (ctx.family != .function) assert.panic("{s}: advising assertions for {f}, which is a {t}, not a function; call assertionFix() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const params = self.s.signature.items()[ctx.parameter_start..][0..ctx.parameter_count];
    const start = self.work.text.used;
    if (params.len == 0) {
        _ = try self.work.text.format("Assert what state '{s}' relies on when it starts and what it guarantees before it returns", .{name});
    } else {
        _ = try self.work.text.format("Assert what '{s}' needs from ", .{name});
        const shown = @min(params.len, 3);
        for (params[0..shown], 0..) |p, i| {
            const separator = if (i == 0) "" else if (i + 1 == shown and shown == params.len) " and " else ", ";
            _ = try self.work.text.format("{s}'{s}'", .{ separator, p.name.text(self.source) });
        }
        if (shown < params.len) _ = try self.work.text.copy(" and the rest");
        _ = try self.work.text.copy(" (a range, a length, how they relate) and what it guarantees before it returns");
    }
    const discounted = weakLines(self, ctx);
    if (discounted > 0) {
        _ = try self.work.text.format("; {d} of its assertions can't fail, so they don't count", .{discounted});
    }
    _ = try self.work.text.copy(". An assertion that can't fail catches nothing.");
    const fix = self.work.text.buffer[start..self.work.text.used];
    if (fix.len <= name.len) assert.panic("{s}: the assertion advice for '{s}' came out as '{s}', shorter than the name; assertionFix() must write the advice around the name, so check its format calls", .{ self.work.facts.path, name, fix });
    if (!std.mem.endsWith(u8, fix, ".")) assert.panic("{s}: the assertion advice for '{s}' does not end with a full stop: '{s}'; end the advice in assertionFix() with a full stop", .{ self.work.facts.path, name, fix });
    return fix;
}

pub fn weakLines(self: *File, ctx: Context) u32 {
    var lines: u32 = 0;
    for (self.s.weak.items()) |w| lines += @intFromBool(w.owner == ctx.serial);
    if (lines > self.s.weak.len) assert.panic("{s}: counted {d} weak assertion lines in {f} but only {d} are recorded; weakLines() must count only entries of s.weak, so check its loop", .{ self.work.facts.path, lines, ctx.node.where(), self.s.weak.len });
    if (ctx.family != .function) assert.panic("{s}: counting weak assertions of {f}, which is a {t}, not a function; call weakLines() only for a function context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    return lines;
}
