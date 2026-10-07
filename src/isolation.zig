//! Tests that are not isolated: they reach state outside themselves that other tests or the
//! machine share, such as environment variables, files, the network, a database or processes.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const scope = @import("scope.zig");
const test_quality = @import("test_quality.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const header = check.header;

/// Reports a call in a test that reaches shared or outside state.
pub fn checkIsolation(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking {f} for isolation, but it is a {t}; call checkIsolation() only from checkTestCall(), with a call context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: the call {f} has an empty name; capture the callee as @call.name in the language's zanity.scm", .{ self.work.facts.path, ctx.node.where() });
    const t = self.tables;
    const at = ctx.callee orelse ctx.name.?;
    if (self.calleeIn(ctx, name, t.process_state_calls)) |m| {
        _ = try self.report(at, "shared-state-in-test", try self.say("'{s}' changes state the whole process shares, so the tests that run after this one see the change.", .{m}));
    }
    if (try filesystemCall(self, ctx, name)) |m| {
        if (try self.report(at, "filesystem-in-test", try self.say("'{s}' reads or changes the real file system, so the test depends on files another machine may not have and can leave changes behind.", .{m}))) {
            if (t.temp_roots.len > 0) self.s.diagnostics.last().?.fix = try self.say("Build the path from `{s}`, the test framework's temporary directory, or pass the code a reader and writer instead of a path.", .{t.temp_roots[0]});
        }
    }
    if (self.calleeIn(ctx, name, t.unmanaged_temp_calls)) |m| {
        _ = try self.report(at, "unmanaged-temp-in-test", try self.say("'{s}' makes a temporary file the test framework doesn't manage, so it can be left behind or collide with another test's.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.network_calls)) |m| {
        _ = try self.report(at, "network-in-test", try self.say("'{s}' makes a real network request, so the test depends on a service being up and answering the same way every time.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.database_calls)) |m| if (!inMemory(self, ctx)) {
        _ = try self.report(at, "database-in-test", try self.say("'{s}' connects to a real database, so the test needs it running and can share rows with other tests.", .{m}));
    };
    if (self.calleeIn(ctx, name, t.stdin_reads)) |m| {
        _ = try self.report(at, "stdin-in-test", try self.say("'{s}' waits for someone to type, so the test hangs wherever nobody is at the keyboard, such as CI.", .{m}));
    }
    if (self.calleeIn(ctx, name, t.process_calls)) |m| {
        _ = try self.report(at, "process-in-test", try self.say("'{s}' starts a real process, so the test depends on what the machine has installed and how fast it runs.", .{m}));
    }
}

/// A statement captured as `@test.shared_state`, such as `global counter` or an assignment to
/// `os.environ[...]`, made inside a test.
pub fn checkSharedStatement(self: *File, node: ts.Node) !void {
    if (!self.inTest()) return;
    const code = header(node.text(self.source));
    if (code.len == 0) assert.panic("{s}: the statement {f} that changes shared state covers no text, so the query matched an empty node; in that language's zanity.scm, put @test.shared_state on the whole statement", .{ self.work.facts.path, node.where() });
    _ = try self.report(node, "shared-state-in-test", try self.say("'{s}' changes state shared beyond this test, so the tests that run after it see the change.", .{code}));
    if (self.s.diagnostics.len > self.s.diagnostics.capacity()) assert.panic("{s}: {d} findings in room for {d}; raise memory.Limits.per_file, or split the file", .{ self.work.facts.path, self.s.diagnostics.len, self.s.diagnostics.capacity() });
}

/// The file system call `ctx` makes, unless it works under the test's own temporary directory.
fn filesystemCall(self: *File, ctx: Context, name: []const u8) !?[]const u8 {
    if (name.len == 0) assert.panic("{s}: looking up the file system call {f} by an empty name; call filesystemCall() only for a call with @call.name captured", .{ self.work.facts.path, ctx.node.where() });
    const t = self.tables;
    const matched = self.calleeIn(ctx, name, t.filesystem_calls) orelse
        (if (ctx.receiver != null and contains(t.filesystem_methods, name)) name else null) orelse return null;
    if (underTemp(self, ctx)) return null;
    if (matched.len == 0) assert.panic("{s}: the file system call {f} matched an empty table entry; remove the empty entry from filesystem_calls in languages/tables.zon", .{ self.work.facts.path, ctx.node.where() });
    return matched;
}

/// Whether the call's receiver or first argument names one of the test's temporary directories,
/// as in `(tmp_path / "out.txt").write_text(...)` or `os.WriteFile(filepath.Join(dir, "x"), ...)`.
fn underTemp(self: *File, ctx: Context) bool {
    if (ctx.family != .call) assert.panic("{s}: looking for a temporary directory in {f}, which is a {t}, not a call; call underTemp() only from filesystemCall(), with a call context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    const roots = self.tables.temp_roots;
    if (roots.len > 16) assert.panic("{s} lists {d} temporary directory names in languages/tables.zon; more than 16 means the table is wrong", .{ self.tables.ecosystem, roots.len });
    const function = test_quality.enclosingTest(self) orelse self.enclosingFunction();
    const body = if (function) |f| f.span.text(self.source) else "";
    for ([_]?ts.Node{ ctx.receiver, ctx.arguments[0] }) |part| {
        const node = part orelse continue;
        if (namesTemp(roots, body, node.text(self.source), 3)) return true;
    }
    return false;
}

/// Whether `text` names a temporary directory: it holds one of `roots`, or is a name that `body`
/// assigns from one, as `path` is after `path = tmp_path / "file.txt"`, following up to `hops`
/// such assignments.
fn namesTemp(roots: []const []const u8, body: []const u8, text: []const u8, hops: u32) bool {
    if (hops > 3) assert.panic("following {d} assignments to find a temporary directory; underTemp() starts at 3", .{hops});
    var current = text;
    for (0..hops + 1) |_| {
        for (roots) |root| if (scope.containsWord(current, root)) return true;
        current = assignedValue(body, leadingName(current)) orelse return false;
    }
    if (current.len > body.len) assert.panic("an assigned value of {d} bytes came from a {d}-byte body; it is a slice of the body", .{ current.len, body.len });
    return false;
}

/// The name an expression starts from: `folder` in `folder / "file.txt"` or `(folder).parent`.
fn leadingName(text: []const u8) []const u8 {
    if (text.len > 1 << 20) assert.panic("reading the leading name of a {d}-byte expression; expressions come from one function", .{text.len});
    const trimmed = std.mem.trimStart(u8, text, " \t(");
    var end: usize = 0;
    while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '_')) end += 1;
    if (end > trimmed.len) assert.panic("the name at the start of '{s}' ran past it", .{text});
    return trimmed[0..end];
}

/// The value `body` first assigns to `name`, on the rest of that line, when `name` is a plain name.
fn assignedValue(body: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0 or body.len == 0) return null;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return null;
    var from: usize = 0;
    for (0..body.len + 1) |_| {
        const at = std.mem.indexOfPos(u8, body, from, name) orelse return null;
        from = at + name.len;
        const before = if (at == 0) ' ' else body[at - 1];
        if (std.ascii.isAlphanumeric(before) or before == '_' or before == '.') continue;
        const after = std.mem.trimStart(u8, body[from..], " \t");
        const plain = after.len > 1 and after[0] == '=' and after[1] != '=';
        if (!plain and !std.mem.startsWith(u8, after, ":=")) continue;
        const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
        const value = std.mem.trimStart(u8, after[0..line_end], ":= \t");
        if (std.mem.indexOfScalar(u8, value, '\n') != null) assert.panic("the value assigned to '{s}' spans lines; it is cut at the first newline", .{name});
        return value;
    }
    if (from > body.len) assert.panic("searched past the end of a {d}-byte body for '{s}'", .{ body.len, name });
    return null;
}

/// Whether one of the connection's first two arguments names a database that lives only in
/// memory: the path, or the address after a driver name as in Go's `sql.Open("sqlite3", ":memory:")`.
fn inMemory(self: *File, ctx: Context) bool {
    if (ctx.family != .call) assert.panic("{s}: looking for an in-memory database in {f}, which is a {t}, not a call; call inMemory() only from checkIsolation(), with a call context", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    for (ctx.arguments) |part| {
        const argument = part orelse continue;
        const text = std.mem.trim(u8, argument.text(self.source), "\"'`");
        for (self.tables.in_memory_databases) |name| {
            if (std.mem.startsWith(u8, text, name)) return true;
        }
    }
    if (self.tables.in_memory_databases.len > 16) assert.panic("{s} lists {d} in-memory database names; more than 16 means the table is wrong, so fix in_memory_databases in languages/tables.zon", .{ self.tables.ecosystem, self.tables.in_memory_databases.len });
    return false;
}
