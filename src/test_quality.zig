//! Checks of test code: how long a test is, how many checks it makes, and the calls in it that
//! make it slow, flaky or dependent on the machine.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const captures = @import("captures.zig");
const extract = @import("extract.zig");
const check = @import("check.zig");
const strings = @import("strings.zig");
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
    // A test that checks nothing, such as one that only imports others, has no behaviour to describe.
    const checks = lines >= rules.max_undocumented_test_lines and ctx.checks > 0;
    if (checks and !documented(self, ctx)) try reportUndocumented(self, at, shown, lines);
    if (lines < rules.max_test_lines) return;
    if (!try self.report(at, "long-test", try self.say("'{s}' has {d} lines of code; tests must have fewer than {d}.", .{ shown, lines, rules.max_test_lines }))) return;
    const fix = try longTestFix(self, ctx);
    if (fix.len > 0) self.s.diagnostics.last().?.fix = fix;
}

fn reportUndocumented(self: *File, at: ts.Node, shown: []const u8, lines: u32) !void {
    if (lines < rules.max_undocumented_test_lines) assert.panic("{s}: '{s}' has {d} lines, under the {d} that need a docstring", .{ self.work.facts.path, shown, lines, rules.max_undocumented_test_lines });
    if (shown.len == 0) assert.panic("{s}: reporting an unnamed test at {f}; pass its name or first line", .{ self.work.facts.path, at.where() });
    if (!try self.report(at, "undocumented-test", try self.say("'{s}' has {d} lines of code and nothing saying which behaviour it checks.", .{ shown, lines }))) return;
    self.s.diagnostics.last().?.fix = try self.say("{s} '{s}' saying which behaviour it checks.", .{ self.tables.test_doc, shown });
}

/// Whether the test tells a reader what it checks: a name written as a sentence, as in
/// `test "..."` or `it("...")`; a comment on the lines just above it, past its attributes and
/// decorators; a comment between its header and its body; or a docstring opening its body.
fn documented(self: *File, ctx: Context) bool {
    const source = self.source;
    if (ctx.name) |name| if (sentence(name.text(source))) return true;
    const in_comment = self.s.in_comment[0..source.len];
    const start = ts.ts_node_start_byte(ctx.node);
    if (start > source.len) assert.panic("{s}: {f} starts at byte {d} of {d}", .{ self.work.facts.path, ctx.node.where(), start, source.len });
    var end = std.mem.lastIndexOfScalar(u8, source[0..start], '\n');
    for (0..max_attribute_lines) |_| {
        const stop = end orelse break;
        const begin = if (std.mem.lastIndexOfScalar(u8, source[0..stop], '\n')) |newline| newline + 1 else 0;
        if (commentLine(source[begin..stop], in_comment[begin..stop])) return true;
        const line = std.mem.trimStart(u8, source[begin..stop], " \t");
        if (!std.mem.startsWith(u8, line, "@") and !std.mem.startsWith(u8, line, "#[")) break;
        end = if (begin == 0) null else begin - 1;
    }
    const inner = ctx.inner orelse return false;
    const body = ts.ts_node_start_byte(inner);
    if (body < start) assert.panic("{s}: the body of {f} starts at byte {d}, before the test at {d}", .{ self.work.facts.path, ctx.node.where(), body, start });
    if (std.mem.indexOfScalar(bool, in_comment[start..body], true) != null) return true;
    const opening = std.mem.trimStart(u8, inner.text(source), " \t\r\n");
    return opening.len > 0 and (opening[0] == '"' or opening[0] == '\'');
}

/// Whether a test's name is a string literal of several words, which says what it checks.
fn sentence(name: []const u8) bool {
    if (name.len == 0) assert.panic("a test's name node has no text; the @name capture matched an empty node", .{});
    const quoted = std.mem.indexOfScalar(u8, "\"'`", name[0]) != null;
    if (quoted and (name.len < 2 or name[name.len - 1] != name[0])) assert.panic("the test name {s} opens with a quote it doesn't close with", .{name});
    return quoted and std.mem.indexOfScalar(u8, name, ' ') != null;
}

/// Lines of attributes, decorators or annotations to look past for a comment above a test.
const max_attribute_lines = 8;

/// Whether a line holds a comment and nothing else.
fn commentLine(line: []const u8, in_comment: []const bool) bool {
    if (line.len != in_comment.len) assert.panic("a {d}-byte line came with {d} comment flags; slice both from the same range", .{ line.len, in_comment.len });
    if (std.mem.indexOfScalar(u8, line, '\n') != null) assert.panic("'{s}' spans more than one line; pass the bytes between two newlines", .{line});
    var commented = false;
    for (line, in_comment) |c, flag| {
        if (std.ascii.isWhitespace(c)) continue;
        if (!flag) return false;
        commented = true;
    }
    return commented;
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

/// A test's length against the tighter limit for tests, its checks if it is a function marked as a
/// test, and its decisions against the usual one.
pub fn closeTest(self: *File, ctx: Context) !void {
    if (ctx.family != .@"test") assert.panic("{s}: closing {f} as a test, but it is a {t}; close() must dispatch each construct by its family, so check its switch", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const name_node = self.functionNameOf(ctx.node);
    const at = name_node orelse ctx.node;
    const shown = if (name_node) |n| n.text(self.source) else header(ctx.node.text(self.source));
    if (name_node orelse ctx.name) |named| try checkTestName(self, named, named.text(self.source));
    try checkTestLength(self, ctx, at, shown);
    try checkEager(self, ctx, at, shown);
    if (name_node) |named| try self.checkAssertionDensity(ctx, self.enclosingFunction().?.*, named);
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
    try checkBranchingDouble(self, ctx, name);
    try checkStorageRead(self, ctx, name);
    const by_shape = self.index.marks(ctx.node, self.v.call_verification);
    const verification = self.calleeIn(ctx, name, self.tables.verification_calls) orelse
        (if (by_shape or (ctx.receiver != null and contains(self.tables.verification_methods, name))) name else null);
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
    if (self.calleeIn(ctx, name, self.tables.module_doubles) != null) return checkModuleDouble(self, ctx, callee);
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

/// A double of a whole module, such as `vi.mock("./mountUtils.js")`. A module of the project's
/// own replaces code the test should run; a package's, such as `vi.mock("node:child_process")`,
/// replaces a dependency, which is how a test isolates itself, so it isn't reported.
fn checkModuleDouble(self: *File, ctx: Context, callee: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} as a module double, but it is a {t}; call checkModuleDouble() only from checkTestDouble()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (callee.len == 0) assert.panic("{s}: the module double {f} has no callee; checkTestDouble() names the double it found", .{ self.work.facts.path, ctx.node.where() });
    const module = modulePath(self, ctx) orelse return;
    if (!strings.startsWithAny(module, self.tables.own_module_prefixes)) return;
    if (!try self.report(ctx.node, "test-double", try self.say("'{s}' replaces '{s}', the project's own module, so the test can pass while the real code is broken.", .{ callee, module }))) return;
    self.s.diagnostics.last().?.fix = try self.say("Let the test run `{s}` for real; if it reaches a boundary such as a network client, give the code under test a parameter to take a fake of that boundary through instead.", .{module});
}

/// The module a module double names in its first argument, without quotes, or null when the
/// argument isn't a plain string.
fn modulePath(self: *File, ctx: Context) ?[]const u8 {
    const first = ctx.arguments[0] orelse return null;
    const text = first.text(self.source);
    if (text.len > 1 << 20) assert.panic("{s}: a call argument of {d} bytes at {f}; arguments come from one file, which is smaller", .{ self.work.facts.path, text.len, first.where() });
    if (text.len < 3) return null;
    const quote = text[0];
    if ((quote != '"' and quote != '\'' and quote != '`') or text[text.len - 1] != quote) return null;
    const inner = text[1 .. text.len - 1];
    if (std.mem.indexOfAny(u8, inner, "\"'`$ \n") != null) return null;
    if (inner.len + 2 != text.len) assert.panic("{s}: the inside of '{s}' came out {d} bytes; a quoted string loses only its quotes", .{ self.work.facts.path, text, inner.len });
    return inner;
}

/// A test double given behaviour that branches on what it is called with, such as
/// `vi.fn((url) => url.includes("/users") ? users : orders)`: the stand-in routes requests the way
/// the thing it replaces does, so the test checks that copy, and a fake that answers every call
/// hides the code calling the wrong one.
pub fn checkBranchingDouble(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} for a branching double, but it is a {t}; call checkBranchingDouble() only from closeCall(), with a call context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const double = self.calleeIn(ctx, name, self.tables.test_doubles) orelse
        (if (ctx.receiver != null and contains(self.tables.double_behaviour_methods, name)) name else null);
    const callee = double orelse return;
    for (ctx.arguments) |maybe| {
        const argument = maybe orelse continue;
        if (!self.index.marks(argument, self.v.double_behaviour)) continue;
        const branch = self.index.within(argument, self.v.double_branch) orelse continue;
        _ = try self.report(branch, "branching-double", try self.say("The stand-in given to '{s}' picks its answer by what it is called with, at '{s}', so it re-implements what it replaces and the test checks that copy.", .{ callee, header(branch.text(self.source)) }));
        return;
    }
}

/// A test, or a helper in a test file, that reads the database directly to check what the code
/// did, through an ORM, such as Drizzle's `db.query.users.findFirst()` or
/// `db.select().from(users)`, or a raw SELECT: it checks the rows rather than what the code's
/// interface returns, so it breaks when the schema changes but the behaviour doesn't.
pub fn checkStorageRead(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} for a storage read, but it is a {t}; call checkStorageRead() only from closeCall()", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const by_method = ctx.receiver != null and contains(self.tables.storage_read_methods, name);
    const by_builder = self.index.marks(ctx.node, self.v.storage_read);
    const by_sql = ctx.receiver == null and contains(self.tables.sql_tags, name) and selects(ctx.node.text(self.source)[name.len..]);
    if (!by_method and !by_builder and !by_sql) return;
    const shown = if (by_method and ctx.callee != null) ctx.callee.?.text(self.source) else header(ctx.node.text(self.source));
    _ = try self.report(ctx.node, "storage-read-in-test", try self.say("'{s}' reads the database directly, so the test checks the rows the code left rather than what its interface returns, and breaks when the schema changes but the behaviour doesn't.", .{shown}));
}

/// Whether a raw SQL template, from its opening quote, is a SELECT.
fn selects(template: []const u8) bool {
    if (template.len > 1 << 20) assert.panic("a SQL template of {d} bytes; templates come from one file, which is smaller", .{template.len});
    const open = std.mem.indexOfAny(u8, template, "`\"'") orelse return false;
    const query = std.mem.trimStart(u8, template[open + 1 ..], " \t\r\n(");
    const keyword = "select";
    if (query.len <= keyword.len) return false;
    if (query.len > template.len) assert.panic("trimming the SQL template '{s}' made it longer", .{template});
    return std.ascii.startsWithIgnoreCase(query, keyword) and std.ascii.isWhitespace(query[keyword.len]);
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
