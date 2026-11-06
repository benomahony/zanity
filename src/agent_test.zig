//! End-to-end tests of what zanity writes for a coding agent: --agent and --all, speaking to Claude
//! Code unless asked otherwise, and environment variables zanity did not set.
const std = @import("std");
const assert = @import("assert.zig");
const paths = @import("paths");
const infer_test = @import("infer_test.zig");
const Io = std.Io;
const golden_test = @import("golden_test.zig");
const exited = golden_test.exited;
const expectOutput = golden_test.expectOutput;

fn checkForAgent(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, flags: []const []const u8) !std.process.RunResult {
    if (flags.len > 2) assert.panic("checkForAgent() takes at most 2 flags, got {d}; add room in argv", .{flags.len});
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    if (!std.fs.path.isAbsolute(zanity)) assert.panic("zanity resolved to the relative path '{s}'; the check runs in tests/agent, so it needs an absolute one", .{zanity});
    var argv: [5][]const u8 = .{ zanity, "check", "a.py", "", "" };
    for (flags, 3..) |flag, i| argv[i] = flag;
    return exited(try std.process.run(arena, io, .{ .argv = argv[0 .. 3 + flags.len], .cwd = .{ .path = "tests/agent" }, .environ_map = environ }), "zanity check for an agent");
}

test "--agent puts the totals and the next command first, then findings up to --limit, then the other rules by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plain = std.process.Environ.Map.init(arena);
    const run = try checkForAgent(arena, std.testing.io, &plain, &.{ "--agent", "--limit=1" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, run.term);
    try std.testing.expect(std.mem.startsWith(u8, run.stdout, "zanity: 2 errors, 2 warnings in 1/1 file; 1 [--fix].\nNext: fix this displayed batch"));
    try expectOutput(run.stdout, &.{
        "rerun the full check with --fail-on warning. This is a selected batch. Resolve the displayed findings in code. If the code is correct, make that correctness explicit enough for the rule to verify; never suppress the finding, disable its rule or exclude its path.\n",
        "\n\nassertion-density [error] 2 in 1 file\n",
        "\n  +1 more: --rules assertion-density --limit 0\n",
        "\nAlso, to see with --rules <name>:\n  unbounded-loop [warning] 1 in 1 file\n  assertion-message [warning] 1 in 1 file\n",
    }, &.{});
}

test "under Claude Code, check speaks to the agent unless --json or --plain asks otherwise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var claude = std.process.Environ.Map.init(arena);
    try claude.put("CLAUDECODE", "1");
    const auto = try checkForAgent(arena, std.testing.io, &claude, &.{});
    try std.testing.expect(std.mem.startsWith(u8, auto.stdout, "zanity: 2 errors"));
    const plain = try checkForAgent(arena, std.testing.io, &claude, &.{"--plain"});
    try std.testing.expect(std.mem.startsWith(u8, plain.stdout, "path=\"a.py\""));
    const both = try checkForAgent(arena, std.testing.io, &claude, &.{ "--agent", "--json" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, both.term);
}

test "environment variables zanity did not set never crash it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var watched = std.process.Environ.Map.init(arena);
    try watched.put("ZANITY_WATCH", "12");
    const rerun = try checkForAgent(arena, std.testing.io, &watched, &.{});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, rerun.term);
    var agent = std.process.Environ.Map.init(arena);
    const unusual = try arena.alloc(u8, 100);
    @memset(unusual, 'x');
    try agent.put("CLAUDECODE", unusual);
    const speaking = try checkForAgent(arena, std.testing.io, &agent, &.{});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, speaking.term);
    // The mock project's zanity.toml sets nothing and its URL is dropped, so zanity would ask
    // TypeSafe, which requires the key; a key it cannot send stops the run before any request.
    var project = try infer_test.InferRun.initInferRun(arena, std.testing.io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(std.testing.io);
    try project.mock.env.put("TYPESAFE_API_KEY", "abc\ndef");
    const dropped = project.mock.env.swapRemove("TYPESAFE_BASE_URL");
    if (!dropped) assert.panic("startMock() set no TYPESAFE_BASE_URL to drop; it points zanity at the mock", .{});
    const inferring = try project.checkInferring(arena, std.testing.io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, inferring.term);
}

test "--all lists every finding on its own line after the totals, with or without Claude Code, and refuses --json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var claude = std.process.Environ.Map.init(arena);
    try claude.put("CLAUDECODE", "1");
    const run = try checkForAgent(arena, std.testing.io, &claude, &.{"--all"});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, run.term);
    try std.testing.expect(std.mem.startsWith(u8, run.stdout,
        \\zanity: 2 errors, 2 warnings in 1/1 file; 1 [--fix].
        \\a.py:1:5: error [assertion-density] 'f' has 1 assertion that can catch a bug; it needs at least 2.
        \\a.py:2:5: warning [unbounded-loop] 'while True' has no bound, so it can run forever.
        \\a.py:3:9: warning [assertion-message] This assertion has no message, so when it fails nobody will know which invariant broke, why it must hold, or with what values.
        \\a.py:6:5: error [assertion-density] 'g' has 0 assertions that can catch a bug; it needs at least 2.
        \\Inspect/export:
    ));
    var plain = std.process.Environ.Map.init(arena);
    const outside = try checkForAgent(arena, std.testing.io, &plain, &.{"--all"});
    try std.testing.expectEqualStrings(run.stdout, outside.stdout);
    const both = try checkForAgent(arena, std.testing.io, &claude, &.{ "--all", "--json" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, both.term);
}
