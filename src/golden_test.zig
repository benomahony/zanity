const std = @import("std");
const paths = @import("paths");
const rules = @import("rules.zig");

const Io = std.Io;

fn behaviour(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const open = std.mem.indexOf(u8, line, " [") orelse return error.MalformedFinding;
        const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse return error.MalformedFinding;
        const rule = rules.find(line[open + 2 .. close]) orelse return error.UnknownRule;
        try findings.append(arena, try std.fmt.allocPrint(arena, "{s} [{s}]\n", .{ line[0..open], rule.name }));
    }
    if (findings.items.len != std.mem.count(u8, std.mem.trim(u8, output, "\n"), "\n") + @intFromBool(output.len > 0)) std.debug.panic("read {d} findings from {d} lines of output:\n{s}", .{ findings.items.len, std.mem.count(u8, std.mem.trim(u8, output, "\n"), "\n") + @intFromBool(output.len > 0), output });
    std.mem.sort([]const u8, findings.items, {}, lineOrder);
    const joined = try std.mem.concat(arena, u8, findings.items);
    if (joined.len < findings.items.len) std.debug.panic("joined {d} findings into {d} bytes; each needs at least a newline", .{ findings.items.len, joined.len });
    return joined;
}

const Record = struct { path: []const u8, line: u32, column: u32, severity: []const u8, rule: []const u8 };

/// zanity's `--json` records in the same normalised form as the expected files.
fn behaviourOfJson(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const records = try std.json.parseFromSliceLeaky([]const Record, arena, output, .{ .ignore_unknown_fields = true });
    var text: std.ArrayList(u8) = .empty;
    for (records) |r| {
        const rule = rules.find(r.rule) orelse return error.UnknownRule;
        if (r.line == 0 or r.column == 0) std.debug.panic("{s}: zanity reported line {d} column {d}; --json counts both from 1", .{ r.path, r.line, r.column });
        try text.print(arena, "{s}:{d}:{d}: {s} [{s}]\n", .{ r.path, r.line, r.column, r.severity, rule.name });
    }
    if (std.mem.count(u8, text.items, "\n") != records.len) std.debug.panic("wrote {d} lines for {d} JSON findings:\n{s}", .{ std.mem.count(u8, text.items, "\n"), records.len, text.items });
    return behaviour(arena, text.items);
}

fn lineOrder(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) std.debug.panic("sorting an empty finding line against '{s}'", .{b});
    if (b.len == 0) std.debug.panic("sorting '{s}' against an empty finding line", .{a});
    return std.mem.order(u8, a, b) == .lt;
}

const Runner = struct { arena: std.mem.Allocator, io: Io, zanity: []const u8 };
const Suite = struct { path: []const u8, dir: Io.Dir };
const Case = struct { name: []const u8, project: bool };

fn caseFailure(runner: Runner, suite: Suite, case: Case) !?[]const u8 {
    const name = case.name;
    const arena = runner.arena;
    const io = runner.io;
    const zanity = runner.zanity;
    if (!std.fs.path.isAbsolute(zanity)) std.debug.panic("the zanity binary path '{s}' is relative; golden cases run in other directories and need an absolute path", .{zanity});
    const stem = if (case.project) name else name[0 .. name.len - std.fs.path.extension(name).len];
    if (stem.len == 0) std.debug.panic("golden case '{s}' has no name before its extension", .{name});
    const expected_file = try suite.dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.expected", .{stem}), arena, .unlimited);
    var lines = std.mem.splitScalar(u8, expected_file, '\n');
    const rules_line = lines.next() orelse "";
    const exit_line = lines.next() orelse "";
    if (!std.mem.startsWith(u8, rules_line, "rules: ") or !std.mem.startsWith(u8, exit_line, "exit: ")) {
        return try std.fmt.allocPrint(arena, "{s}: expected file must start with 'rules: ' and 'exit: ' lines", .{name});
    }
    const expected_exit = try std.fmt.parseInt(u8, exit_line["exit: ".len..], 10);
    const expected_out = try behaviour(arena, lines.rest());
    const result = try std.process.run(arena, io, .{
        .argv = &.{ zanity, "check", "--json", "--rules", rules_line["rules: ".len..], if (case.project) "." else name },
        .cwd = .{ .path = if (case.project) try std.fs.path.join(arena, &.{ suite.path, name }) else suite.path },
    });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    const actual_out = behaviourOfJson(arena, result.stdout) catch |e| return try std.fmt.allocPrint(arena, "{s}: could not read the JSON findings ({t}):\n{s}{s}", .{ name, e, result.stdout, result.stderr });
    if (exit_code == expected_exit and std.mem.eql(u8, actual_out, expected_out)) return null;
    return try std.fmt.allocPrint(arena, "{s}\n--- expected (exit {d})\n{s}--- actual (exit {d})\n{s}{s}", .{ name, expected_exit, expected_out, exit_code, actual_out, result.stderr });
}

test "golden cases reproduce the source tools' findings through the CLI" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var root = try Io.Dir.cwd().openDir(io, "tests/golden", .{ .iterate = true });
    defer root.close(io);
    var failures: usize = 0;
    var total: usize = 0;
    var suites = root.iterate();
    while (try suites.next(io)) |suite_entry| {
        if (suite_entry.kind != .directory) continue;
        const suite_path = try std.fmt.allocPrint(arena, "tests/golden/{s}", .{suite_entry.name});
        var suite = try root.openDir(io, suite_entry.name, .{ .iterate = true });
        defer suite.close(io);
        var cases = suite.iterate();
        while (try cases.next(io)) |case| {
            if (std.mem.endsWith(u8, case.name, ".expected")) continue;
            if (case.kind != .file and case.kind != .directory) continue;
            total += 1;
            const this: Case = .{ .name = case.name, .project = case.kind == .directory };
            if (try caseFailure(.{ .arena = arena, .io = io, .zanity = zanity }, .{ .path = suite_path, .dir = suite }, this)) |failure| {
                failures += 1;
                std.debug.print("\n[{s}] {s}\n", .{ suite_entry.name, failure });
            }
        }
    }
    if (failures > 0) std.debug.print("\n{d} of {d} golden cases failed\n", .{ failures, total });
    try std.testing.expect(total > 0);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "zanity passes its own checks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const result = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "build.zig", "src", "languages" } });
    if (result.stdout.len > 0) std.debug.print("\n{s}", .{result.stdout});
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "a run ends with a summary on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const clean = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--rules", "parse-error", "tests/golden/zig/empty_containers.zig" } });
    try std.testing.expectEqualStrings("", clean.stdout);
    try std.testing.expectEqualStrings("zanity: checked 1 file, no issues found\n", clean.stderr);
    const dirty = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--rules", "assertion-density,long-parameter-list", "tests/golden/structure/shapes.py", "tests/golden/structure/shapes_zig.zig" } });
    try std.testing.expectEqualStrings("zanity: 15 errors and 3 warnings in 2 of 2 files\n", dirty.stderr);
}

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
    var cases: usize = 0;
    var it = fixtures.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.name, ".fixed")) continue;
        cases += 1;
        const input = try fixtures.readFileAlloc(io, entry.name, arena, .unlimited);
        const expected = try fixtures.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.fixed", .{entry.name}), arena, .unlimited);
        try tmp.dir.writeFile(io, .{ .sub_path = entry.name, .data = input });
        for (0..2) |_| _ = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--fix", entry.name }, .cwd = .{ .path = work } });
        const actual = try tmp.dir.readFileAlloc(io, entry.name, arena, .unlimited);
        std.testing.expectEqualStrings(expected, actual) catch |e| {
            std.debug.print("\n--fix of tests/fix/{s} differs from its .fixed file\n", .{entry.name});
            return e;
        };
    }
    try std.testing.expect(cases > 0);
}

/// Starts tests/infer/mock_typesafe.py and returns it with the port it listens on.
fn startMock(arena: std.mem.Allocator, io: Io, log: []const u8, env: *std.process.Environ.Map) !struct { child: std.process.Child, port: []const u8 } {
    if (log.len == 0) std.debug.panic("the mock TypeSafe server needs a log path to record requests in", .{});
    try env.put("MOCK_TYPESAFE_LOG", log);
    var child = try std.process.spawn(io, .{ .argv = &.{ "python3", "tests/infer/mock_typesafe.py" }, .stdout = .pipe, .environ_map = env });
    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const port = try reader.interface.takeDelimiterExclusive('\n');
    if (port.len == 0 or port.len > 5) std.debug.panic("the mock TypeSafe server printed '{s}' instead of a port", .{port});
    return .{ .child = child, .port = try arena.dupe(u8, port) };
}

test "--infer asks only about functions that report errors, and caches every answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try tmp.dir.writeFile(io, .{ .sub_path = "service.py", .data = try Io.Dir.cwd().readFileAlloc(io, "tests/infer/project/service.py", arena, .unlimited) });
    const log = try Io.Dir.cwd().realPathFileAlloc(io, work, arena);
    var env = std.process.Environ.Map.init(arena);
    var mock = try startMock(arena, io, try std.fs.path.join(arena, &.{ log, "requests.log" }), &env);
    defer mock.child.kill(io);
    try env.put("TYPESAFE_API_KEY", "test");
    try env.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ log, "store.db" }));
    try env.put("TYPESAFE_BASE_URL", try std.fmt.allocPrint(arena, "http://127.0.0.1:{s}", .{mock.port}));
    var outputs: [2][]const u8 = undefined;
    var timings: [2][]const u8 = undefined;
    for (&outputs, &timings) |*out, *timing| {
        const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", ".", "--infer", "--plain" }, .cwd = .{ .path = work }, .environ_map = &env });
        out.* = run.stdout;
        timing.* = run.stderr;
    }
    try std.testing.expectEqualStrings(outputs[0], outputs[1]);
    if (std.mem.indexOf(u8, timings[1], ", 0 asked of TypeSafe") == null) std.debug.print("\nthe second run was not served from the store:\n{s}", .{timings[1]});
    try std.testing.expect(std.mem.indexOf(u8, timings[1], ", 0 asked of TypeSafe") != null);
    try std.testing.expect(std.mem.indexOf(u8, timings[0], ", 0 asked of TypeSafe") == null);
    for ([_][]const u8{ "rule=\"misleading-error\"", "rule=\"unconstructive-error\"", "'invalid input' doesn't say" }) |expected| {
        if (std.mem.indexOf(u8, outputs[0], expected) == null) std.debug.print("\nmissing {s} in:\n{s}", .{ expected, outputs[0] });
        try std.testing.expect(std.mem.indexOf(u8, outputs[0], expected) != null);
    }
    const requests = try tmp.dir.readFileAlloc(io, "requests.log", arena, .unlimited);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, requests, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, requests, "def fine") == null);
}

test "zanity.toml disables rules and excludes paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--plain", "." }, .cwd = .{ .path = "tests/config/project" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, run.term);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "long-parameter-list") == null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "vendor/") == null);
    try std.testing.expectEqualStrings("zanity: checked 1 file, no issues found\n", run.stderr);
}

test "a mistake in zanity.toml stops the run and says where" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--plain", "." }, .cwd = .{ .path = "tests/config/broken" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, run.term);
    try std.testing.expect(std.mem.indexOf(u8, run.stderr, "zanity.toml:1: 'recursions' isn't a rule") != null);
}
