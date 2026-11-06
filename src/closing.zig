//! What happens when the walk leaves a construct: each call, loop, assignment, assertion,
//! statement and function is checked once its parts have all been captured.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const facts_module = @import("facts.zig");
const messages = @import("messages.zig");
const hazards = @import("hazards.zig");
const tracing = @import("tracing.zig");
const secrets = @import("secrets.zig");
const weak = @import("weak.zig");
const types = @import("types.zig");
const test_quality = @import("test_quality.zig");
const strings = @import("strings.zig");
const parameters = @import("parameters.zig");
const repeats = @import("repeats.zig");
const shapes = @import("shapes.zig");
const notes = @import("notes.zig");
const extract = @import("extract.zig");
const loops = @import("loops.zig");
const naming = @import("naming.zig");
const passthrough = @import("passthrough.zig");
const contains = strings.contains;
const header = strings.header;
const check = @import("check.zig");
const Context = check.Context;
const Assertion = check.Assertion;
const File = check.File;

pub fn remember(self: *File, ctx: Context) !void {
    const parent = self.parentOf(ctx.node) orelse return;
    if (ctx.family != .statement) assert.panic("{s}: remembering a {t} ({f}) as the previous statement; only statements are remembered", .{ self.work.facts.path, ctx.family, ctx.node.where() });
    if (ctx.trail_mark > self.s.trail.len) assert.panic("{s}: the statement {f} marked {d} summaries, but only {d} remain; remember() must trim the trail back to the statement's mark, never below it", .{ self.work.facts.path, ctx.node.where(), ctx.trail_mark, self.s.trail.len });
    self.s.trail.len = ctx.trail_mark;
    const key = parent.key();
    for (self.s.trail.items()) |*entry| {
        if (entry.parent.id == key.id and entry.parent.start == key.start) {
            entry.summary = ctx.summary;
            return;
        }
    }
    try self.s.trail.add(.{ .parent = key, .summary = ctx.summary });
}

pub fn close(self: *File, ctx: Context) !void {
    if (ts.ts_node_end_byte(ctx.span) > ts.ts_node_end_byte(ctx.node)) assert.panic("{s}: the {t} {f} was widened to {f}, which ends after it; refines() may only widen a construct to a node inside it", .{ self.work.facts.path, ctx.family, ctx.node.where(), ctx.span.where() });
    if (ts.ts_node_start_byte(ctx.span) < ts.ts_node_start_byte(ctx.node)) assert.panic("{s}: the {t} {f} was widened to {f}, which starts before it; refines() may only widen a construct to a node inside it", .{ self.work.facts.path, ctx.family, ctx.node.where(), ctx.span.where() });
    switch (ctx.family) {
        .call => try closeCall(self, ctx),
        .loop => try closeLoop(self, ctx),
        .assertion => try closeAssertion(self, ctx),
        .assignment => try closeAssignment(self, ctx),
        .function => try closeFunction(self, ctx),
        .statement => try remember(self, ctx),
        .@"test" => try test_quality.closeTest(self, ctx),
        .class, .control => {},
        .definition => try naming.closeDefinition(self, ctx),
    }
}

pub fn closeCall(self: *File, ctx: Context) !void {
    if (ctx.family != .call) assert.panic("{s}: closing {f} as a call, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    try self.s.calls.add(.{
        .key = ctx.node.key(),
        .name = ctx.name,
        .receiver = ctx.receiver != null,
        .arguments = ctx.arguments,
        .count = ctx.argument_count,
    });
    const name_node = ctx.name orelse return;
    const name = name_node.text(self.source);
    if (name.len == 0) assert.panic("{s}: @call.name matched the empty {f}; capture the callee's identifier", .{ self.work.facts.path, name_node.where() });
    try hazards.checkForbiddenCall(self, ctx, name);
    if (self.calleeIn(ctx, name, self.tables.debug_calls)) |matched| {
        _ = try self.report(ctx.callee orelse name_node, "debug-leftover", try self.say("'{s}' is debugging code: wherever it ships it stops the program or dumps its state.", .{matched}));
    }
    const reports_error = self.calleeIn(ctx, name, self.tables.error_calls) != null or (ctx.receiver != null and contains(self.tables.error_methods, name));
    if (reports_error and self.innermost(.assertion) == null) {
        if (ctx.arguments[0]) |message| try messages.checkMessage(self, message, null);
    }
    try hazards.checkRiskyCall(self, ctx, name);
    try tracing.checkSpanCall(self, ctx, name);
    if (self.inTest()) {
        try test_quality.checkTestCall(self, ctx, name);
    } else if (self.inTestFile()) {
        try test_quality.checkTestDouble(self, ctx, name);
        try test_quality.checkBranchingDouble(self, ctx, name);
        try test_quality.checkStorageRead(self, ctx, name);
    }
    const allocating = self.calleeIn(ctx, name, self.tables.allocating_calls) orelse (if (contains(self.tables.allocating_calls, name)) name else null);
    if (allocating) |matched| try checkAllocation(self, ctx, matched);
    try repeats.noteCallWrites(self, ctx, name);
    if (contains(self.tables.mutating_calls, name) and inAssertionCondition(self, ctx.node)) {
        _ = try self.report(ctx.node, "assertion-side-effect", try self.say("This assertion calls '{s}', which changes state, so the program behaves differently when assertions are disabled.", .{name}));
    }
    const function = self.enclosingFunction() orelse return;
    const caller = function.fact orelse return;
    if (ctx.receiver) |receiver| {
        if (!contains(self.tables.self_receivers, receiver.text(self.source))) return;
        try self.work.facts.call(.{ .caller = caller, .callee = name, .reach = .methods, .arguments = ctx.argument_count, .types = try types.ofArguments(self, &ctx) });
        return;
    }
    try self.s.bare_calls.add(.{ .owner = function.serial, .text = name, .arguments = ctx.argument_count, .types = try types.ofArguments(self, &ctx) });
}

pub fn inAssertionCondition(self: *File, node: ts.Node) bool {
    const assertion = self.innermost(.assertion) orelse return false;
    const condition = assertion.condition orelse return false;
    if (ts.ts_node_start_byte(condition) < ts.ts_node_start_byte(assertion.node)) assert.panic("{s}: @assertion.condition captured {f}, before its assertion {f}; capture it inside @assertion.outer", .{ self.work.facts.path, condition.where(), assertion.node.where() });
    if (ts.ts_node_end_byte(condition) > ts.ts_node_end_byte(assertion.node)) assert.panic("{s}: @assertion.condition captured {f}, after its assertion {f} ends; capture it inside @assertion.outer", .{ self.work.facts.path, condition.where(), assertion.node.where() });
    return ts.ts_node_start_byte(node) >= ts.ts_node_start_byte(condition) and ts.ts_node_end_byte(node) <= ts.ts_node_end_byte(condition);
}

pub fn checkAllocation(self: *File, ctx: Context, callee: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking the allocation in {f}, which is a {t}, not a call; call checkAllocation() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (callee.len == 0) assert.panic("{s}: the allocating call {f} has an empty callee; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    if (self.inTest() or self.inTestFile()) return;
    const function = self.enclosingFunction() orelse return;
    const owner = function.name.?.text(self.source);
    for (self.tables.initializer_prefixes) |prefix| if (std.mem.startsWith(u8, owner, prefix)) return;
    const shown = if (ctx.callee) |c| c.text(self.source) else callee;
    _ = try self.report(ctx.node, "dynamic-allocation", try self.say("'{s}' allocates memory after initialization in '{s}', so memory use depends on input and can fail at any point.", .{ shown, owner }));
}

pub fn closeLoop(self: *File, ctx: Context) !void {
    if (ctx.family != .loop) assert.panic("{s}: closing {f} as a loop, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (ctx.has_sleep) {
        _ = try self.report(ctx.node, "polling-loop", try self.say("This loop polls with a sleep, so the test's speed and outcome depend on timing.", .{}));
    }
    if (ctx.condition != null and ctx.iterable != null) assert.panic("{s}: the loop {f} has both @loop.condition and @loop.iterable; a loop is one or the other, so fix its query", .{ self.work.facts.path, ctx.node.where() });
    const unbounded = if (ctx.condition) |c| self.index.marks(c, self.v.literal_true) else ctx.iterable == null;
    if (!unbounded) return;
    if (try self.report(ctx.node, "unbounded-loop", try self.say("'{s}' has no bound, so it can run forever.", .{header(ctx.node.text(self.source))}))) {
        self.s.diagnostics.last().?.fix = try loops.unboundedFix(self, ctx.node);
    }
}

pub fn closeAssignment(self: *File, ctx: Context) !void {
    if (ctx.family != .assignment) assert.panic("{s}: closing {f} as an assignment, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (inAssertionCondition(self, ctx.node)) {
        _ = try self.report(ctx.node, "assertion-side-effect", try self.say("This assertion assigns a variable, so the program behaves differently when assertions are disabled.", .{}));
    }
    if (self.index.marks(ctx.node, self.v.assignment_compound)) return;
    const lhs = ctx.lhs orelse return;
    const rhs = ctx.rhs orelse return;
    try secrets.checkSecret(self, ctx.node, lhs, rhs);
    if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(rhs)) assert.panic("{s}: in the assignment {f}, @assignment.lhs {f} overlaps @assignment.rhs {f}; the query captured the wrong nodes", .{ self.work.facts.path, ctx.node.where(), lhs.where(), rhs.where() });
    const statement = self.statementOf(ctx.node) orelse return;
    statement.summary = .{ .assignment = .{ .lhs = lhs, .rhs = rhs } };
}

pub fn closeAssertion(self: *File, ctx: Context) !void {
    if (ctx.family != .assertion) assert.panic("{s}: closing {f} as an assertion, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    try messages.checkAssertion(self, ctx);
    const condition = ctx.condition orelse return;
    try test_quality.checkConstantAssertion(self, ctx.node, condition);
    if (ctx.message != null and ts.ts_node_start_byte(condition) > ts.ts_node_start_byte(ctx.message.?)) assert.panic("{s}: in the assertion {f}, @assertion.message {f} comes before @assertion.condition {f}; the query captured them the wrong way round", .{ self.work.facts.path, ctx.node.where(), ctx.message.?.where(), condition.where() });
    const function = self.enclosingFunction() orelse return;
    try weak.restatedType(self, function, ctx.node, condition);
    const statement = self.statementOf(ctx.node) orelse return;
    statement.summary = .{ .assertion = .{ .node = ctx.node, .condition = condition } };
    const here: Assertion = .{ .function = function, .node = ctx.node, .condition = condition };
    switch (statement.previous) {
        .assignment => |previous| try weak.afterAssignment(self, here, previous.lhs, previous.rhs),
        .assertion => |previous| try weak.afterAssertion(self, here, previous.node, previous.condition),
        .none => {},
    }
}

pub fn closeFunction(self: *File, ctx: Context) !void {
    if (ctx.family != .function) assert.panic("{s}: closing {f} as a function, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    try notes.resolveBareCalls(self, ctx);
    const name_node = ctx.name orelse return;
    const name = name_node.text(self.source);
    if (name.len == 0) assert.panic("{s}: @function.name matched the empty {f}; capture the function's identifier", .{ self.work.facts.path, name_node.where() });
    const last = ts.ts_node_end_point(ctx.span).row;
    try checkFunctionLength(self, ctx, name_node, name);
    try parameters.checkParameterCount(self, ctx, name_node, name);
    try parameters.checkUnusedParameters(self, ctx, name);
    try repeats.checkRepeats(self, ctx, name);
    try shapes.recordShape(self, ctx);
    try extract.checkExtractable(self, ctx, name);
    if (self.index.marks(ctx.span, self.v.function_passthrough) or self.index.marks(ctx.node, self.v.function_passthrough)) try passthrough.checkPassthrough(self, ctx, name_node, name);
    try weak.checkAssertionDensity(self, ctx, ctx, name_node);
    try tracing.checkUnendedSpan(self, ctx);
    if (ctx.decisions + 1 > rules.max_complexity) {
        if (try self.report(name_node, "complex-function", try self.say("'{s}' makes {d} decisions (cyclomatic complexity {d}), past the {d} a reader can follow and a test suite can cover.", .{ name, ctx.decisions, ctx.decisions + 1, rules.max_complexity }))) self.s.diagnostics.last().?.fix = try extract.decisionsFix(self, ctx, name);
    }
    if (self.work.facts.collect_units and !self.index.marks(ctx.node, self.v.test_outer)) {
        const at = ts.ts_node_start_point(name_node);
        const kind: facts_module.UnitKind = if (ctx.is_test) .@"test" else if (self.inTestFile()) .fixture else .function;
        var span = ctx.span;
        if (kind == .fixture) if (self.parentOf(span)) |parent| {
            const starts_before = ts.ts_node_start_byte(parent) < ts.ts_node_start_byte(span);
            if (starts_before and ts.ts_node_end_byte(parent) == ts.ts_node_end_byte(span)) span = parent;
        };
        try self.work.facts.unit(name, @import("documentation.zig").sourceWithComments(span, self.source, &self.index, self.checker.compiled.id("unit.prefix")), .{ .kind = kind, .reports_error = ctx.has_message, .at = .{ at.row, at.column, last } });
    }
}

/// A function's assertions against the function minimum, or a test's checks against the test
/// minimum: a test is itself the check on the code it calls, so one check that can fail is enough.
/// A fixture or helper in a test file is not measured: the tests that use it check what it does.
/// A function marked as a test by an attribute or annotation is measured by closeTest, which
/// holds its checks; `function` is the function context, which owns its weak assertions.
/// A function against the function limit, or a test named as one (`test_x`, `TestX`) against the
/// tighter test limit. A test marked by an attribute or annotation is also a test construct,
/// and closeTest measures it.
pub fn checkFunctionLength(self: *File, ctx: Context, name_node: ts.Node, name: []const u8) !void {
    if (ctx.family != .function) assert.panic("{s}: measuring {f} as a function, but it is a {t}; call checkFunctionLength() only from closeFunction()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (!std.mem.eql(u8, name, name_node.text(self.source))) assert.panic("{s}: measuring '{s}' under the name of {f}; pass the function's own name node and its text", .{ self.work.facts.path, name, name_node.where() });
    if (self.index.marks(ctx.node, self.v.test_outer)) return;
    if (ctx.is_test) {
        try test_quality.checkEager(self, ctx, name_node, name);
        try test_quality.checkTestName(self, name_node, name);
    }
    const lines = self.codeLinesIn(ctx.span);
    if (ctx.is_test) {
        try test_quality.checkTestLength(self, ctx, name_node, name);
    } else if (lines >= rules.max_function_lines) {
        _ = try self.report(name_node, "long-function", try self.say("'{s}' has {d} lines of code; functions must have fewer than {d}.", .{ name, lines, rules.max_function_lines }));
    }
}
