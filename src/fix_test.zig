//! End-to-end tests of `zanity check --fix`: each fixture rewritten into its .fixed file with
//! nothing left to fix, and the fixes particular rules make.
const std = @import("std");
const assert = @import("assert.zig");
const paths = @import("paths");
const Io = std.Io;
const golden_test = @import("golden_test.zig");
const expectOutput = golden_test.expectOutput;

/// One --fix fixture, fixed twice in its own copy on its own thread.
const FixRun = struct {
    name: []const u8,
    zanity: []const u8,
    fixtures: Io.Dir,
    work: []const u8,
    io: Io,
    arena: std.heap.ArenaAllocator,
    matched: bool = false,
    err: ?anyerror = null,

    fn fixTwice(job: *FixRun) void {
        if (job.name.len == 0) assert.panic("a --fix fixture has no name; the directory listing never gives empty names", .{});
        job.matched = job.compare() catch |e| {
            job.err = e;
            return;
        };
        if (job.matched and job.err != null) assert.panic("tests/fix/{s} both matched and errored; fixTwice() records one or the other", .{job.name});
    }

    fn compare(job: *FixRun) !bool {
        if (!std.fs.path.isAbsolute(job.zanity)) assert.panic("running --fix with zanity at '{s}', a relative path, from {s}; resolve it before changing directory", .{ job.zanity, job.work });
        if (std.mem.endsWith(u8, job.name, ".fixed")) assert.panic("treating the expected output tests/fix/{s} as a fixture; the test must skip .fixed files", .{job.name});
        const arena = job.arena.allocator();
        const input = try job.fixtures.readFileAlloc(job.io, job.name, arena, .unlimited);
        const expected = try job.fixtures.readFileAlloc(job.io, try std.fmt.allocPrint(arena, "{s}.fixed", .{job.name}), arena, .unlimited);
        var work = try Io.Dir.cwd().openDir(job.io, job.work, .{});
        defer work.close(job.io);
        try work.writeFile(job.io, .{ .sub_path = job.name, .data = input });
        for (0..2) |_| _ = try std.process.run(arena, job.io, .{ .argv = &.{ job.zanity, "check", "--fix", job.name }, .cwd = .{ .path = job.work } });
        const actual = try work.readFileAlloc(job.io, job.name, arena, .unlimited);
        if (std.mem.eql(u8, expected, actual)) return true;
        std.debug.print("\n--fix of tests/fix/{s} differs from its .fixed file\n--- expected\n{s}--- actual\n{s}", .{ job.name, expected, actual });
        return false;
    }
};

test "--fix rewrites each fixture into its .fixed file and leaves nothing more to fix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var fixtures = try Io.Dir.cwd().openDir(io, "tests/fix", .{ .iterate = true });
    defer fixtures.close(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    var jobs: std.ArrayList(FixRun) = .empty;
    defer for (jobs.items) |*job| job.arena.deinit();
    var it = fixtures.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".fixed")) continue;
        try jobs.append(arena, .{ .name = try arena.dupe(u8, entry.name), .zanity = zanity, .fixtures = fixtures, .work = work, .io = io, .arena = .init(std.heap.page_allocator) });
    }
    var group: Io.Group = .init;
    for (jobs.items) |*job| group.async(io, FixRun.fixTwice, .{job});
    try group.await(io);
    var differ: usize = 0;
    for (jobs.items) |job| {
        if (job.err) |e| return e;
        differ += @intFromBool(!job.matched);
    }
    try std.testing.expect(jobs.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), differ);
}

test "unbounded-loop's fix names where the loop stops, leaving out breaks of inner loops and continues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "loops.py", .data = "def poll(q):\n    while True:\n        for x in q.get():\n            if x:\n                break\n        if q.empty():\n            return None\n        continue\n\n\ndef spin():\n    while True:\n        pass\n" });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--rules", "unbounded-loop", "--plain", "loops.py" }, .cwd = .{ .path = work } });
    try expectOutput(run.stdout, &.{ "fix=\"It stops only at line 7 (`return None`); add a limit", "fix=\"Give it a condition, or a limit such as a maximum number of attempts: nothing in it stops it" }, &.{});
}

test "--fix deletes a null check that the type check after it makes redundant" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "checks.py", .data = "def f(x):\n    assert x is not None\n    assert isinstance(x, int)\n    return x\n" });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    _ = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--fix", "--rules", "redundant-null-check", "checks.py" }, .cwd = .{ .path = work } });
    try std.testing.expectEqualStrings("def f(x):\n    assert isinstance(x, int)\n    return x\n", try tmp.dir.readFileAlloc(io, "checks.py", arena, .unlimited));
}

test "precedence-trap's fix shows how the code runs and the grouping it reads as" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "traps.ts", .data = "export function f(a: number, b: number, c: number, y: boolean): void {\n  if (!y == true) {}\n  if (a & b == c) {}\n  if (a == b & c) {}\n}\n" });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--rules", "precedence-trap", "--plain", "traps.ts" }, .cwd = .{ .path = work } });
    try expectOutput(run.stdout, &.{ "It runs as `(!y) == true`; if you meant `!(y == true)`", "It runs as `a & (b == c)`; if you meant `(a & b) == c`", "It runs as `(a == b) & c`; if you meant `a == (b & c)`" }, &.{});
}
