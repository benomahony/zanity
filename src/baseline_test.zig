const std = @import("std");
const Io = std.Io;
const paths = @import("paths");
const assert = @import("assert.zig");
const Row = @import("baseline.zig").Row;

const Envelope = struct {
    summary: struct { new: usize, existing: usize, resolved: usize },
    pagination: struct { matching_total: usize, returned: usize, next_offset: ?usize },
    findings: []const Row,
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.mem.Allocator,
    exe: []const u8,
    work: []const u8,

    fn initFixture(arena: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const exe = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, paths.zanity, arena);
        const work = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
        if (!std.fs.path.isAbsolute(exe)) assert.panic("test executable is relative: {s}", .{exe});
        if (!std.fs.path.isAbsolute(work)) assert.panic("test workspace is relative: {s}", .{work});
        return .{ .tmp = tmp, .arena = arena, .exe = exe, .work = work };
    }

    fn write(self: *Fixture, source: []const u8) !void {
        if (self.work.len == 0) assert.panic("fixture has no workspace", .{});
        if (source.len == 0) assert.panic("fixture source must exercise findings", .{});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.py", .data = source });
    }

    fn check(self: *Fixture, flags: []const []const u8) !std.process.RunResult {
        if (self.exe.len == 0) assert.panic("fixture has no executable", .{});
        if (flags.len > 64) assert.panic("fixture has {d} flags, above its intended bound", .{flags.len});
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(self.arena, &.{ self.exe, "check", ".", "--rules", "assertion-message" });
        try args.appendSlice(self.arena, flags);
        var environ = std.process.Environ.Map.init(self.arena);
        try environ.put("OTEL_SDK_DISABLED", "true");
        return std.process.run(self.arena, std.testing.io, .{ .argv = args.items, .cwd = .{ .path = self.work }, .environ_map = &environ });
    }

    fn runWatchProbe(self: *Fixture) !std.process.RunResult {
        if (self.exe.len == 0) assert.panic("watch probe has no executable", .{});
        if (self.work.len == 0) assert.panic("watch probe has no workspace", .{});
        return std.process.run(self.arena, std.testing.io, .{ .argv = &.{ "python3", "-c", watch_probe, self.exe, self.work } });
    }

    fn json(self: *Fixture, flags: []const []const u8, code: u8) !Envelope {
        if (code > 2) assert.panic("fixture expects non-CLI status {d}", .{code});
        if (flags.len > 64) assert.panic("JSON fixture has {d} flags", .{flags.len});
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(self.arena, flags);
        try args.append(self.arena, "--json");
        const run = try self.check(args.items);
        if (run.term != .exited or run.term.exited != code) std.debug.print("unexpected check: {s}\n{s}\n", .{ run.stdout, run.stderr });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, run.term);
        return std.json.parseFromSliceLeaky(Envelope, self.arena, run.stdout, .{ .ignore_unknown_fields = true });
    }
};

fn initLegacy(arena: std.mem.Allocator) !Fixture {
    var fixture = try Fixture.initFixture(arena);
    errdefer fixture.tmp.cleanup();
    var source: std.Io.Writer.Allocating = .init(arena);
    for (0..10000) |i| try source.writer.print("assert value_{d}\n", .{i});
    try fixture.write(source.written());
    const capture = try fixture.json(&.{ "--baseline", "backlog.json", "--capture-baseline", "--limit", "1" }, 0);
    try std.testing.expectEqual(@as(usize, 10000), capture.findings.len);
    if (source.written().len < 10000) assert.panic("legacy source has only {d} bytes", .{source.written().len});
    if (capture.pagination.matching_total != 10000) assert.panic("legacy capture matched {d} findings", .{capture.pagination.matching_total});
    return fixture;
}

test "explicit baseline records all 10000 findings and unchanged new-only succeeds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try initLegacy(arena);
    defer fixture.tmp.cleanup();
    const original = try fixture.tmp.dir.readFileAlloc(std.testing.io, "backlog.json", arena, .unlimited);
    const saved = try std.json.parseFromSliceLeaky(struct { findings: []const Row }, arena, original, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 10000), saved.findings.len);
    const unchanged = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--fail-on", "warning" }, 0);
    try std.testing.expectEqual(@as(usize, 10000), unchanged.summary.existing);
    try std.testing.expectEqual(@as(usize, 0), unchanged.summary.new);
    try std.testing.expectEqual(@as(usize, 0), unchanged.summary.resolved);
}

test "triage pages traverse 10000 IDs without duplication or loss" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try initLegacy(arena);
    defer fixture.tmp.cleanup();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var offset: usize = 0;
    while (offset < 10000) : (offset += 1000) {
        const page = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--triage", "--page-size", "1000", "--offset", try std.fmt.allocPrint(arena, "{d}", .{offset}) }, 0);
        try std.testing.expectEqual(@as(usize, 10000), page.pagination.matching_total);
        for (page.findings) |row| {
            const entry = try seen.getOrPut(arena, row.id);
            try std.testing.expect(!entry.found_existing);
        }
    }
    try std.testing.expectEqual(@as(u32, 10000), seen.count());
    const batch = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--triage" }, 0);
    try std.testing.expectEqual(@as(usize, 20), batch.findings.len);
    try std.testing.expectEqual(@as(?usize, 20), batch.pagination.next_offset);
}

test "filtered export contains full details for matching rule and file only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try initLegacy(arena_state.allocator());
    defer fixture.tmp.cleanup();
    const filtered = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--rule", "assertion-message", "--file", "a.py", "--page-size", "20" }, 0);
    for (filtered.findings) |row| {
        try std.testing.expectEqualStrings("a.py", row.path);
        try std.testing.expectEqualStrings("assertion-message", row.rule);
        try std.testing.expect(row.message.len > 0 and row.fix.len > 0 and row.id.len == 64);
    }
    const empty = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--rule", "other-rule" }, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.pagination.matching_total);
}

test "fixing 100 findings cannot hide one new warning and checks never update baseline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try initLegacy(arena);
    defer fixture.tmp.cleanup();
    const original = try fixture.tmp.dir.readFileAlloc(std.testing.io, "backlog.json", arena, .unlimited);
    var changed: std.Io.Writer.Allocating = .init(arena);
    for (100..10000) |i| try changed.writer.print("assert value_{d}\n", .{i});
    try changed.writer.writeAll("assert regression\n");
    try fixture.write(changed.written());
    const regression = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--fail-on", "warning" }, 1);
    try std.testing.expectEqual(@as(usize, 1), regression.summary.new);
    try std.testing.expectEqual(@as(usize, 100), regression.summary.resolved);
    try std.testing.expectEqualStrings(original, try fixture.tmp.dir.readFileAlloc(std.testing.io, "backlog.json", arena, .unlimited));
    _ = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only" }, 0);
}

test "explicit update accepts all current findings despite report filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try Fixture.initFixture(arena_state.allocator());
    defer fixture.tmp.cleanup();
    try fixture.write("assert old\n");
    _ = try fixture.json(&.{ "--baseline", "backlog.json", "--capture-baseline" }, 0);
    try fixture.write("assert new\n");
    const update = try fixture.json(&.{ "--baseline", "backlog.json", "--update-baseline", "--rule", "nonmatching-rule", "--page-size", "1" }, 0);
    try std.testing.expectEqual(@as(usize, 1), update.summary.new);
    try std.testing.expectEqual(@as(usize, 1), update.summary.resolved);
    const accepted = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--fail-on", "warning" }, 0);
    try std.testing.expectEqual(@as(usize, 1), accepted.summary.existing);
    try std.testing.expectEqual(@as(usize, 0), accepted.summary.new);
}

test "identity survives line shifts and same-file moves but changes for renamed files and edited anchors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fixture = try Fixture.initFixture(arena_state.allocator());
    defer fixture.tmp.cleanup();
    try fixture.write("def f(x):\n    assert x\n    assert x\n");
    const captured = try fixture.json(&.{ "--baseline", "b.json", "--capture-baseline" }, 0);
    try std.testing.expectEqual(@as(usize, 2), captured.findings.len);
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    for (captured.findings) |row| try unique.put(fixture.arena, row.id, {});
    try std.testing.expectEqual(@as(u32, 2), unique.count());
    try fixture.write("# unrelated\n\ndef f(x):\n    assert x\n    assert x\n");
    const shifted = try fixture.json(&.{ "--baseline", "b.json", "--new-only" }, 0);
    try std.testing.expectEqual(@as(usize, 2), shifted.summary.existing);
    try std.testing.expectEqualStrings(captured.findings[0].id, shifted.findings[0].id);
    try std.testing.expectEqual(captured.findings[0].line + 2, shifted.findings[0].line);
    try fixture.write("def moved(x):\n    assert x\n    assert x\n");
    const moved = try fixture.json(&.{ "--baseline", "b.json", "--new-only" }, 0);
    try std.testing.expectEqual(@as(usize, 2), moved.summary.existing);
    try fixture.write("def moved(x):\n    assert x\n    assert x > 0\n");
    const edited = try fixture.json(&.{ "--baseline", "b.json", "--new-only", "--fail-on", "warning" }, 1);
    try std.testing.expectEqual(@as(usize, 1), edited.summary.new);
    try std.testing.expectEqual(@as(usize, 1), edited.summary.resolved);
    try fixture.tmp.dir.rename("a.py", fixture.tmp.dir, "renamed.py", std.testing.io);
    const renamed = try fixture.json(&.{ "--baseline", "b.json", "--new-only", "--fail-on", "warning" }, 1);
    try std.testing.expectEqual(@as(usize, 2), renamed.summary.new);
    try std.testing.expectEqual(@as(usize, 2), renamed.summary.resolved);
}

test "corrupt incompatible and accidental baseline mutations fail explicitly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try Fixture.initFixture(arena);
    defer fixture.tmp.cleanup();
    try fixture.write("assert x\n");
    for ([_][]const u8{ "not json", "{\"schema_version\":99,\"identity_version\":1,\"findings\":[]}", "{\"schema_version\":1,\"identity_version\":99,\"findings\":[]}" }) |data| {
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.json", .data = data });
        const run = try fixture.check(&.{ "--baseline", "bad.json", "--new-only" });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, run.term);
        try std.testing.expect(std.mem.indexOf(u8, run.stderr, "Cannot load baseline") != null);
        try std.testing.expectEqualStrings(data, try fixture.tmp.dir.readFileAlloc(std.testing.io, "bad.json", arena, .unlimited));
    }
    _ = try fixture.json(&.{ "--baseline", "b.json", "--capture-baseline" }, 0);
    const repeated = try fixture.check(&.{ "--baseline", "b.json", "--capture-baseline" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 74 }, repeated.term);
    for ([_][]const []const u8{ &.{"--new-only"}, &.{ "--capture-baseline", "--baseline", "b.json", "--watch" }, &.{ "--page-size", "0" } }) |flags| {
        const run = try fixture.check(flags);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, run.term);
    }
}

test "agent distinguishes 10000 inherited findings from two new correction targets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try initLegacy(arena);
    defer fixture.tmp.cleanup();
    const original = try fixture.tmp.dir.readFileAlloc(std.testing.io, "a.py", arena, .unlimited);
    try fixture.write(try std.mem.concat(arena, u8, &.{ original, "assert regression_one\nassert regression_two\n" }));
    const run = try fixture.check(&.{ "--baseline", "backlog.json", "--agent" });
    for ([_][]const u8{ "2 new, 10000 existing (inherited backlog), 0 resolved", "Assignment: fix new findings only.", "Shown 2; matching total 10002", "Inspect/export: zanity", "--json --offset 0 --page-size 10000" }) |expected| try std.testing.expect(std.mem.indexOf(u8, run.stdout, expected) != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, run.stdout, "Resolve every finding"));
    const current = try fixture.json(&.{ "--baseline", "backlog.json", "--new-only", "--limit", "1" }, 0);
    try std.testing.expectEqual(@as(usize, 10002), current.findings.len);
}

const watch_probe =
    \\import json, pathlib, queue, subprocess, sys, threading
    \\exe, work = sys.argv[1:]
    \\root = pathlib.Path(work)
    \\baseline = (root / 'backlog.json').read_bytes()
    \\p = subprocess.Popen([exe, 'check', '.', '--rules', 'assertion-message', '--baseline', 'backlog.json', '--new-only', '--watch', '--json'], cwd=work, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    \\q = queue.Queue()
    \\threading.Thread(target=lambda: [q.put(line) for line in p.stdout], daemon=True).start()
    \\try:
    \\    first = json.loads(q.get(timeout=30))
    \\    assert first['summary'] == {'new': 2, 'existing': 10000, 'resolved': 0}, first
    \\    source = root / 'a.py'
    \\    source.write_text(''.join(source.read_text().splitlines(keepends=True)[:-2]))
    \\    for _ in range(8):
    \\        after = json.loads(q.get(timeout=30))
    \\        if after['summary']['new'] == 0:
    \\            break
    \\    assert after['summary'] == {'new': 0, 'existing': 10000, 'resolved': 0}, after
    \\    assert len(after['resolved_since_previous']) == 2, after['resolved_since_previous']
    \\    assert (root / 'backlog.json').read_bytes() == baseline, 'watch rewrote the baseline'
    \\finally:
    \\    p.terminate()
    \\    p.wait(timeout=10)
;

test "watch reports two new findings resolving while retaining all inherited backlog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try initLegacy(arena);
    defer fixture.tmp.cleanup();
    const original = try fixture.tmp.dir.readFileAlloc(std.testing.io, "a.py", arena, .unlimited);
    try fixture.write(try std.mem.concat(arena, u8, &.{ original, "assert regression_one\nassert regression_two\n" }));
    const run = try fixture.runWatchProbe();
    if (run.term != .exited or run.term.exited != 0) std.debug.print("watch probe failed: {s}\n{s}\n", .{ run.stdout, run.stderr });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, run.term);
}
