//! Checks of test code: how long a test is, how many checks it makes, and the calls in it that
//! make it slow, flaky or dependent on the machine.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const captures = @import("captures.zig");
const extract = @import("extract.zig");
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
        const ctx = &items[i];
        switch (ctx.family) {
            .class => return null,
            .@"test" => return ctx,
            .function => if (ctx.is_test) return ctx,
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
    if (!try self.report(at, "eager-test", try self.say("'{s}' makes {d} checks; past {d}, a failure no longer says which behaviour broke.", .{ shown, ctx.checks, rules.max_test_checks }))) return;
    const runs = checkRuns(self, ctx);
    if (runs.count >= 2) {
        self.s.diagnostics.last().?.fix = try runsFix(self, runs);
    } else if (runs.first_check) |row| {
        self.s.diagnostics.last().?.fix = try self.say("Its checks all follow one step, from line {d}; keep those that check what its name promises, and move the rest into tests named for what they check.", .{row + 1});
    }
}

/// Where a test's checks are: the line of the first, and the runs of checks separated by other
/// steps, each a behaviour of its own, with the first line of up to three of them.
const Runs = struct { first_check: ?u32 = null, first_step: u32 = 0, count: usize = 0, starts: [3]u32 = undefined };

/// The test's top-level steps grouped into runs of checks, an assertion or a `std.testing.expect`
/// style call, between steps that act.
fn checkRuns(self: *File, ctx: Context) Runs {
    var runs: Runs = .{};
    if (ctx.family != .@"test" and !ctx.is_test) assert.panic("{s}: grouping the checks of {f}, which is not a test", .{ self.work.facts.path, ctx.node.where() });
    if (ctx.inner == null) return runs;
    var statements: [256]ts.Node = undefined;
    const count = extract.topStatements(self, ctx, &statements);
    if (count == 0) return runs;
    runs.first_step = ts.ts_node_start_point(statements[0]).row;
    const ids = [_]?captures.Id{ self.v.test_check, self.checker.compiled.id("assertion.outer") };
    var in_run = false;
    for (statements[0..count]) |statement| {
        var checks: u32 = 0;
        for (ids) |maybe| if (maybe) |id| {
            checks += extract.capturesIn(self, statement, id);
        };
        const row = ts.ts_node_start_point(statement).row;
        const checking = checks > 0;
        if (checking and runs.first_check == null) runs.first_check = row;
        if (checking and !in_run) {
            if (runs.count < runs.starts.len) runs.starts[runs.count] = row;
            runs.count += 1;
        }
        in_run = checking;
    }
    if (runs.first_check) |row| if (row < runs.first_step) assert.panic("{s}: the first check of {f} is on line {d}, before its first step on {d}", .{ self.work.facts.path, ctx.node.where(), row + 1, runs.first_step + 1 });
    return runs;
}

/// A test at or past the length limit for tests, with where to split it or what setup to move out.
pub fn checkTestLength(self: *File, ctx: Context, at: ts.Node, shown: []const u8) !void {
    if (shown.len == 0) assert.panic("{s}: measuring an unnamed test {f}; pass its name or first line", .{ self.work.facts.path, ctx.node.where() });
    if (ctx.family != .@"test" and !ctx.is_test) assert.panic("{s}: measuring {f} as a test, but it is neither a test construct nor test-named", .{ self.work.facts.path, ctx.node.where() });
    const lines = self.codeLinesIn(ctx.span);
    if (lines < rules.max_test_lines) return;
    if (!try self.report(at, "long-test", try self.say("'{s}' has {d} lines of code; tests must have fewer than {d}.", .{ shown, lines, rules.max_test_lines }))) return;
    const fix = try longTestFix(self, ctx);
    if (fix.len > 0) self.s.diagnostics.last().?.fix = fix;
}

/// A long test's fix: move the setup out when most of it comes before the first check, or split it
/// at its runs of checks; empty when neither applies.
fn longTestFix(self: *File, ctx: Context) ![]const u8 {
    const runs = checkRuns(self, ctx);
    const first = runs.first_check orelse return "";
    if (runs.count == 0) assert.panic("{s}: {f} has a first check on line {d} but no run of checks; checkRuns() starts a run at every first check", .{ self.work.facts.path, ctx.node.where(), first + 1 });
    const last = ts.ts_node_end_point(ctx.span).row;
    if (last < runs.first_step) assert.panic("{s}: {f} ends on line {d}, before its first step on {d}", .{ self.work.facts.path, ctx.node.where(), last + 1, runs.first_step + 1 });
    if ((first - runs.first_step) * 2 >= last - runs.first_step) {
        return self.say("Lines {d}-{d} set things up before its first check on line {d}; move that setup into a fixture or helper named for what it builds.", .{ runs.first_step + 1, first, first + 1 });
    }
    if (runs.count >= 2) return runsFix(self, runs);
    return self.say("Lines {d}-{d} check the result of one step; keep the checks its name promises and move the rest into tests named for what they check.", .{ first + 1, last + 1 });
}

/// A test that checks after several separate steps: name where each run of checks starts.
fn runsFix(self: *File, runs: Runs) ![]const u8 {
    if (runs.count < 2) assert.panic("{s}: advising how to split a test with {d} run of checks; runsFix() needs two or more", .{ self.work.facts.path, runs.count });
    const text = self.work.text;
    const start = text.used;
    _ = try text.format("It checks after {d} separate steps, from lines ", .{runs.count});
    const shown = @min(runs.count, runs.starts.len);
    for (runs.starts[0..shown], 0..) |row, i| {
        _ = try text.format("{s}{d}", .{ if (i == 0) "" else if (i + 1 == shown and runs.count == shown) " and " else ", ", row + 1 });
    }
    if (runs.count > shown) _ = try text.format(" and {d} more", .{runs.count - shown});
    _ = try text.copy("; give each step a test of its own, named for what it checks.");
    if (text.used <= start) assert.panic("{s}: wrote no fix for a test with {d} runs of checks", .{ self.work.facts.path, runs.count });
    return text.buffer[start..text.used];
}

/// A test's length against the tighter limit for tests, and its decisions against the usual one.
pub fn closeTest(self: *File, ctx: Context) !void {
    if (ctx.family != .@"test") assert.panic("{s}: closing {f} as a test, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const name_node = self.functionNameOf(ctx.node);
    const at = name_node orelse ctx.node;
    const shown = if (name_node) |n| n.text(self.source) else header(ctx.node.text(self.source));
    if (name_node orelse ctx.name) |named| try checkTestName(self, named, named.text(self.source));
    try checkTestLength(self, ctx, at, shown);
    try checkEager(self, ctx, at, shown);
    if (ctx.decisions + 1 > rules.max_complexity) {
        _ = try self.report(at, "complex-function", try self.say("'{s}' makes {d} decisions (cyclomatic complexity {d}), past the {d} a reader can follow and a test suite can cover.", .{ shown, ctx.decisions, ctx.decisions + 1, rules.max_complexity }));
    }
    if (shown.len == 0) assert.panic("{s}: the test {f} has no first line to name it by; capture a test node with text as @test.outer in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const facts = self.work.facts;
    // A test with no name and no checks, like Zig's `test { _ = @import("x.zig"); }`, only pulls
    // other tests in; it checks no behaviour for --infer to judge.
    const gathers_only = name_node == null and ctx.name == null and ctx.checks == 0;
    if (facts.collect_units and !gathers_only) {
        const start = ts.ts_node_start_point(at);
        try facts.unit(shown, ctx.span.text(self.source), .{ .kind = .@"test", .reports_error = false, .at = .{ start.row, start.column, ts.ts_node_end_point(ctx.span).row } });
    }
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
    const callee = double orelse return;
    var buffer: [256]u8 = undefined;
    const target = patchTarget(self, ctx, &buffer);
    if (target.len > 0 and boundary(self, target)) return;
    if (!try self.report(ctx.node, "test-double", try self.say("'{s}' replaces real behaviour with a stand-in, so the test can pass while the real code is broken.", .{callee}))) return;
    self.s.diagnostics.last().?.fix = if (target.len > 0)
        try self.say("It replaces `{s}`: if that is the project's own code, let the test run it for real; if it is a boundary such as a network client or a keychain, give the code under test a parameter to take a fake through instead of patching it.", .{target})
    else if (patches(callee))
        try self.say("Instead of patching with `{s}`, give the code under test a parameter to take a fake through, or let it run for real.", .{callee})
    else
        try self.say("Instead of a `{s}` with no behaviour of its own, pass in a small fake that behaves like the real thing.", .{callee});
}

/// Whether a test double replaces something in place, as `patch` and `monkeypatch.setattr` do,
/// rather than being a stand-in object, as `Mock()` and `jest.fn()` are.
fn patches(callee: []const u8) bool {
    if (callee.len == 0) assert.panic("asked whether an empty callee patches; checkTestDouble() names the double it found", .{});
    const words = [_][]const u8{ "patch", "setattr", "spy", "replace", "stubGlobal", "mock.mock", "doMock", ".mock" };
    for (words) |word| if (std.ascii.findIgnoreCase(callee, word) != null) return true;
    if (callee.len > 256) assert.panic("a test double's callee is {d} bytes; callees from the tables are short", .{callee.len});
    return false;
}

/// What a patch replaces, as a dotted path: the string `patch("pkg.mod.fn")` names, or the object
/// and attribute `patch.object(mod, "fn")` and `monkeypatch.setattr(mod, "fn", fake)` name. Empty
/// for a double that replaces nothing by name, such as `Mock()`.
fn patchTarget(self: *File, ctx: Context, buffer: []u8) []const u8 {
    if (buffer.len < 64) assert.panic("{s}: naming a patch target in {d} bytes; give patchTarget() room for a dotted path", .{ self.work.facts.path, buffer.len });
    const first = ctx.arguments[0] orelse return "";
    const first_text = first.text(self.source);
    if (unquoted(first_text)) |path| return path;
    const second = ctx.arguments[1] orelse return "";
    const attribute = unquoted(second.text(self.source)) orelse return "";
    const joined = std.fmt.bufPrint(buffer, "{s}.{s}", .{ first_text, attribute }) catch return "";
    if (joined.len != first_text.len + attribute.len + 1) assert.panic("{s}: joined '{s}' and '{s}' into '{s}'; bufPrint writes both with a dot between", .{ self.work.facts.path, first_text, attribute, joined });
    return joined;
}

/// The text inside a quoted string literal that holds a dotted name, or null for anything else.
fn unquoted(text: []const u8) ?[]const u8 {
    if (text.len > 1 << 20) assert.panic("a call argument of {d} bytes; arguments come from one file, which is smaller", .{text.len});
    if (text.len < 3) return null;
    const quote = text[0];
    if ((quote != '"' and quote != '\'') or text[text.len - 1] != quote) return null;
    const inner = text[1 .. text.len - 1];
    for (inner) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return null;
    if (inner.len + 2 != text.len) assert.panic("the inside of '{s}' came out {d} bytes; a quoted string loses only its quotes", .{ text, inner.len });
    return inner;
}

/// Whether `target` is a boundary the language's tables list, such as `time.monotonic`,
/// `requests.get` or `subprocess.run`, or lives in the same module as one: replacing those with a
/// fake is what isolates a test, so it isn't a test double to report.
fn boundary(self: *File, target: []const u8) bool {
    if (target.len == 0) assert.panic("{s}: asked whether an empty target is a boundary; patchTarget() returns empty only when nothing is named", .{self.work.facts.path});
    const t = self.tables;
    const tables = [_][]const []const u8{ t.network_calls, t.nondeterministic, t.sleeps, t.filesystem_calls, t.process_calls, t.database_calls, t.stdin_reads, t.wall_clocks };
    const module = target[0 .. std.mem.indexOfScalar(u8, target, '.') orelse target.len];
    for (tables) |table| for (table) |entry| {
        if (std.mem.eql(u8, entry, target) or std.mem.endsWith(u8, target, entry)) return true;
        const entry_module = entry[0 .. std.mem.indexOfScalar(u8, entry, '.') orelse entry.len];
        if (std.mem.indexOfScalar(u8, entry, '.') != null and std.mem.eql(u8, entry_module, module)) return true;
    };
    if (module.len > target.len) assert.panic("{s}: the module of '{s}' came out longer than it", .{ self.work.facts.path, target });
    return false;
}

/// A test whose name doesn't say what behaviour it expects, such as `test_1`, `it("works")`, or,
/// outside Go, `test_parse`: a failure then names the test without saying what broke.
pub fn checkTestName(self: *File, at: ts.Node, name: []const u8) !void {
    if (ts.ts_node_end_byte(at) <= ts.ts_node_start_byte(at)) assert.panic("{s}: the test name '{s}' is reported at the empty {f}; pass the node of the test's name or string", .{ self.work.facts.path, name, at.where() });
    const shown = std.mem.trim(u8, name, "\"'`");
    if (shown.len == 0) return;
    var words: u32 = 0;
    var it: naming.Words = .{ .text = shown };
    while (it.next()) |word| {
        if (!fillerWord(word)) words += 1;
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
