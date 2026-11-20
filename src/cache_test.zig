const std = @import("std");
const Io = std.Io;
const paths = @import("paths");
const assert = @import("assert.zig");
/// The exit status zclig gives a command that failed on input or output.
const io_status = 74;

fn checkWithStore(arena: std.mem.Allocator, work: []const u8, store_path: []const u8) !std.process.RunResult {
    const exe = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, paths.zanity, arena);
    if (!std.fs.path.isAbsolute(exe) or !std.fs.path.isAbsolute(work)) assert.panic("checking {s} with {s}; resolve both to absolute paths first", .{ work, exe });
    var environ = std.process.Environ.Map.init(arena);
    try environ.put("OTEL_SDK_DISABLED", "true");
    try environ.put("ZANITY_STORE", store_path);
    return std.process.run(arena, std.testing.io, .{ .argv = &.{ exe, "check", "--no-color", "." }, .cwd = .{ .path = work }, .environ_map = &environ });
}

test "a check whose analysis cache can't be written fails and says why" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "work");
    const work = try tmp.dir.realPathFileAlloc(std.testing.io, "work", arena);
    const store_path = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena), "store.db" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/a.py", .data = "def first(x):\n    return x\n" });
    const stored = try checkWithStore(arena, work, store_path);
    if (stored.term != .exited or stored.term.exited > 1) std.debug.print("the first check failed: {s}\n", .{stored.stderr});
    try std.testing.expect(stored.term == .exited and stored.term.exited <= 1);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/a.py", .data = "def second(y):\n    return y\n" });
    var store_file = try tmp.dir.openFile(std.testing.io, "store.db", .{});
    try store_file.setPermissions(std.testing.io, .fromMode(0o444));
    store_file.close(std.testing.io);
    const refused = try checkWithStore(arena, work, store_path);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = io_status }, refused.term);
    try std.testing.expect(std.mem.indexOf(u8, refused.stderr, "Could not use the analysis cache for a.py") != null);
}
