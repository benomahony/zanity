//! Native behavioral coverage, independent of which languages external reference tools support.
const std = @import("std");
const language = @import("language.zig");
const adapters = @import("adapters");

/// The common deterministic test checks every language must exercise through the golden CLI suite.
const common = [_][]const u8{
    "eager-test",    "long-test",          "sleep-in-test",
    "polling-loop",  "filesystem-in-test", "network-in-test",
    "stdin-in-test", "process-in-test",    "nondeterministic-test",
    "skipped-test",  "vague-test-name",    "constant-test-assertion",
};

test "every language has behavioral fixtures for every common deterministic test check" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/golden", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var covered: [language.count][common.len]bool = @splat(@splat(false));
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".expected")) continue;
        const bytes = try dir.readFileAlloc(io, entry.path, arena, .unlimited);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const adapter = language.forPath(line[0..colon]) orelse continue;
            for (common, 0..) |rule, i| {
                const marker = try std.fmt.allocPrint(arena, " [{s}]", .{rule});
                if (std.mem.endsWith(u8, line, marker)) covered[language.indexOf(adapter)][i] = true;
            }
        }
    }
    var missing: usize = 0;
    for (adapters.all, covered) |adapter, checks| {
        for (common, checks) |rule, found| {
            if (found) continue;
            std.debug.print("\n{s}: no golden finding exercises {s}; add a positive fixture and its negative controls", .{ adapter.name, rule });
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}
