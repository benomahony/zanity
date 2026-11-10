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
        if (std.fs.path.dirname(job.name)) |parent| try work.createDirPath(job.io, parent);
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
    // A fixture keeps its path under tests/fix, so one under .github/workflows/ is read as a workflow.
    var walker = try fixtures.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.basename, ".fixed")) continue;
        try jobs.append(arena, .{ .name = try arena.dupe(u8, entry.path), .zanity = zanity, .fixtures = fixtures, .work = work, .io = io, .arena = .init(std.heap.page_allocator) });
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

test "--fix renames a non-canonical name in every file that writes it, unless the new name is taken or the name is one word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][3][]const u8{
        .{ "zanity.toml", "[vocabulary.synonyms]\ninvoice = [\"bill\"]\ncustomer = [\"client\"]\n", "" },
        .{ "billing.py", "def send_bill(total):\n    return total\n\n\ndef bill():\n    return 1\n", "def send_invoice(total):\n    return total\n\n\ndef bill():\n    return 1\n" },
        .{ "main.py", "from billing import send_bill\n\n# send_bill posts it\nprint(send_bill(3), resend_bill)\n", "from billing import send_invoice\n\n# send_invoice posts it\nprint(send_invoice(3), resend_bill)\n" },
        .{ "app.ts", "export function loadClient(id: number): number {\n  return id;\n}\nexport const x = loadClient(1);\n", "export function loadCustomer(id: number): number {\n  return id;\n}\nexport const x = loadCustomer(1);\n" },
        .{ "main.go", "package main\n\nfunc FetchBill() int { return 1 }\n\nfunc main() { _ = FetchBill(); FetchInvoice() }\n\nfunc FetchInvoice() {}\n", "" },
    };
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--fix", "--plain", "--rules", "non-canonical-term", "." }, .cwd = .{ .path = work } });
    try expectOutput(run.stdout, &.{ "fix=\"Rename it to 'invoice'.\"", "fix=\"Rename it to 'FetchInvoice' by hand: 'FetchInvoice' is already written at main.go:5, so --fix leaves it.\"" }, &.{"send_bill"});
    try expectOutput(run.stderr, &.{"fixed 2 findings in 3 files"}, &.{});
    for (files) |f| {
        const expected = if (f[2].len > 0) f[2] else f[1];
        try std.testing.expectEqualStrings(expected, try tmp.dir.readFileAlloc(io, f[0], arena, .unlimited));
    }
}
