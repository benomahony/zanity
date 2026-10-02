//! Tests that are not isolated: they reach state outside themselves that other tests or the
//! machine share, such as environment variables, files, the network, a database or processes.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const scope = @import("scope.zig");
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
        _ = try self.report(at, "filesystem-in-test", try self.say("'{s}' reads or changes the real file system, so the test depends on files another machine may not have and can leave changes behind.", .{m}));
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
    for ([_]?ts.Node{ ctx.receiver, ctx.arguments[0] }) |part| {
        const node = part orelse continue;
        const text = node.text(self.source);
        for (roots) |root| if (scope.containsWord(text, root)) return true;
    }
    return false;
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
