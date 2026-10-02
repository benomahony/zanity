//! Checks of test code: how long a test is, how many checks it makes, and the calls in it that
//! make it slow, flaky or dependent on the machine.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const check = @import("check.zig");
const isolation = @import("isolation.zig");
const naming = @import("naming.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;

/// The innermost test: a test construct, or a function named as a test (`test_x`, `TestX`).
/// Code in a callback or helper inside a test counts toward that test.
pub fn enclosingTest(self: *File) ?*Context {
    const items = self.s.contexts.items();
    if (items.len > self.s.contexts.capacity()) assert.panic("{s}: {d} open constructs in room for {d}; raise memory.Limits.depth, or check that leave() pops what enter() opened", .{ self.work.facts.path, items.len, self.s.contexts.capacity() });
    var i = items.len;
    while (i > 0) {
        i -= 1;
        switch (items[i].family) {
            .class => return null,
            .@"test" => return &items[i],
            .function => if (items[i].is_test) return &items[i],
            else => {},
        }
    }
    if (i != 0) assert.panic("{s}: the search for an enclosing test stopped at depth {d} without returning; the loop in enclosingTest() must return from inside, so check its exits", .{ self.work.facts.path, i });
    return null;
}

/// A test that makes more checks than a failure can point at.
pub fn checkEager(self: *File, ctx: Context, at: ts.Node, shown: []const u8) !void {
    if (ctx.family != .@"test" and !ctx.is_test) assert.panic("{s}: counting the checks of {f}, which is not a test; call checkEager() only for a test construct or a test-named function", .{ self.work.facts.path, ctx.node.where() });
    if (shown.len == 0) assert.panic("{s}: the test {f} has no name to show; pass the test's name or first line", .{ self.work.facts.path, ctx.node.where() });
    if (ctx.checks <= rules.max_test_checks) return;
    _ = try self.report(at, "eager-test", try self.say("'{s}' makes {d} checks; past {d}, a failure no longer says which behaviour broke.", .{ shown, ctx.checks, rules.max_test_checks }));
}

/// A test's length against the tighter limit for tests, and its decisions against the usual one.
pub fn closeTest(self: *File, ctx: Context) !void {
    if (ctx.family != .@"test") assert.panic("{s}: closing {f} as a test, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const name_node = self.functionNameOf(ctx.node);
    const at = name_node orelse ctx.node;
    const shown = if (name_node) |n| n.text(self.source) else header(ctx.node.text(self.source));
    if (name_node orelse ctx.name) |named| try checkTestName(self, named, named.text(self.source));
    const lines = self.codeLinesIn(ctx.span);
    if (lines >= rules.max_test_lines) {
        _ = try self.report(at, "long-test", try self.say("'{s}' has {d} lines of code; tests must have fewer than {d}.", .{ shown, lines, rules.max_test_lines }));
    }
    try checkEager(self, ctx, at, shown);
    if (ctx.decisions + 1 > rules.max_complexity) {
        _ = try self.report(at, "complex-function", try self.say("'{s}' makes {d} decisions (cyclomatic complexity {d}), past the {d} a reader can follow and a test suite can cover.", .{ shown, ctx.decisions, ctx.decisions + 1, rules.max_complexity }));
    }
    if (shown.len == 0) assert.panic("{s}: the test {f} has no first line to name it by; capture a test node with text as @test.outer in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
}

pub fn checkTestCall(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} as a test call, but it is a {t}; call checkTestCall() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the test call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    if (self.calleeIn(ctx, name, self.tables.sleeps)) |callee| {
        _ = try self.report(ctx.node, "sleep-in-test", try self.say("'{s}' makes this test wait on the clock, which slows the suite and hides timing bugs.", .{callee}));
        for (self.s.contexts.items()) |*open_ctx| if (open_ctx.family == .loop) {
            open_ctx.has_sleep = true;
        };
    }
    if (self.calleeIn(ctx, name, self.tables.nondeterministic)) |callee| {
        _ = try self.report(ctx.node, "nondeterministic-test", try self.say("'{s}' returns a different value on every run, so this test can pass or fail by chance.", .{callee}));
    }
    try checkTestDouble(self, ctx, name);
    const verification = self.calleeIn(ctx, name, self.tables.verification_calls) orelse
        (if (ctx.receiver != null and contains(self.tables.verification_methods, name)) name else null);
    if (verification) |callee| {
        _ = try self.report(ctx.callee orelse ctx.name.?, "call-verification", try self.say("'{s}' checks how the code was called rather than what it did, so a change that keeps the behaviour breaks the test.", .{callee}));
    }
    try isolation.checkIsolation(self, ctx, name);
}

/// A mock, stub, spy or patch, in a test or anywhere in a test file, such as a fixture or a
/// `@patch` decorator, which runs before the test it replaces behaviour for.
pub fn checkTestDouble(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} for a test double, but it is a {t}; call checkTestDouble() only from closeCall(), with a call context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const double = self.calleeIn(ctx, name, self.tables.test_doubles) orelse (if (ctx.receiver == null and contains(self.tables.test_doubles, name)) name else null);
    if (double) |callee| {
        _ = try self.report(ctx.node, "test-double", try self.say("'{s}' replaces real behaviour with a stand-in, so the test can pass while the real code is broken.", .{callee}));
    }
}

/// A test whose name doesn't say what behaviour it expects, such as `test_1`, `it("works")`, or,
/// outside Go, `test_parse`: a failure then names the test without saying what broke.
pub fn checkTestName(self: *File, at: ts.Node, name: []const u8) !void {
    if (ts.ts_node_end_byte(at) <= ts.ts_node_start_byte(at)) assert.panic("{s}: the test name '{s}' is reported at the empty {f}; pass the node of the test's name or string", .{ self.work.facts.path, name, at.where() });
    const shown = std.mem.trim(u8, name, "\"'`");
    if (shown.len == 0) return;
    var words: u32 = 0;
    var start: usize = 0;
    for (0..shown.len + 1) |i| {
        const at_end = i == shown.len;
        const separator = !at_end and !std.ascii.isAlphanumeric(shown[i]);
        const boundary = !at_end and !separator and i > start and naming.caseBoundary(shown, i);
        if (!at_end and !separator and !boundary) continue;
        if (i > start and !fillerWord(shown[start..i])) words += 1;
        start = if (separator) i + 1 else i;
    }
    if (words > shown.len) assert.panic("{s}: counted {d} words in the {d}-byte test name '{s}'; a word needs at least one byte, so check the loop in checkTestName()", .{ self.work.facts.path, words, shown.len, shown });
    if (words >= self.tables.test_name_words) return;
    const message = if (words == 0)
        try self.say("'{s}' doesn't say what it tests, so when it fails nobody knows what broke.", .{shown})
    else
        try self.say("'{s}' names what it tests but not what should happen, so when it fails nobody knows which behaviour broke.", .{shown});
    _ = try self.report(at, "vague-test-name", message);
}

/// Whether a word of a test's name says nothing about what it checks, once a trailing number is dropped.
fn fillerWord(word: []const u8) bool {
    if (word.len == 0) assert.panic("asked whether an empty word is filler; checkTestName() must skip empty words", .{});
    const stem = std.mem.trimEnd(u8, word, "0123456789");
    if (stem.len == 0) return true;
    for (rules.filler_test_words) |filler| {
        if (filler.len == 0) assert.panic("rules.filler_test_words holds an empty word, which would match nothing; remove it", .{});
        if (std.ascii.eqlIgnoreCase(stem, filler)) return true;
    }
    return false;
}
