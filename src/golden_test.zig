const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const paths = @import("paths");
const rules = @import("rules.zig");
const schema = @import("schema.zig");

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
    if (findings.items.len != std.mem.count(u8, std.mem.trim(u8, output, "\n"), "\n") + @intFromBool(output.len > 0)) assert.panic("read {d} findings from {d} lines of output; behaviour() must keep one finding per line, so check how it splits:\n{s}", .{ findings.items.len, std.mem.count(u8, std.mem.trim(u8, output, "\n"), "\n") + @intFromBool(output.len > 0), output });
    std.mem.sort([]const u8, findings.items, {}, strings.lessThan);
    const joined = try std.mem.concat(arena, u8, findings.items);
    if (joined.len < findings.items.len) assert.panic("joined {d} findings into {d} bytes; each needs at least a newline, so check that behaviour() writes each finding's line", .{ findings.items.len, joined.len });
    return joined;
}

const Record = struct { path: []const u8, line: u32, column: u32, severity: []const u8, rule: []const u8 };

/// zanity's `--json` records in the same normalised form as the expected files.
fn behaviourOfJson(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const records = try std.json.parseFromSliceLeaky([]const Record, arena, output, .{ .ignore_unknown_fields = true });
    var text: std.ArrayList(u8) = .empty;
    for (records) |r| {
        const rule = rules.find(r.rule) orelse return error.UnknownRule;
        if (r.line == 0 or r.column == 0) assert.panic("{s}: zanity reported line {d} column {d}; --json counts both from 1, so fix the JSON row built in runCheck(), which adds 1 to both", .{ r.path, r.line, r.column });
        try text.print(arena, "{s}:{d}:{d}: {s} [{s}]\n", .{ r.path, r.line, r.column, r.severity, rule.name });
    }
    if (std.mem.count(u8, text.items, "\n") != records.len) assert.panic("wrote {d} lines for {d} JSON findings; behaviourOfJson() must write one line per finding, so check its loop:\n{s}", .{ std.mem.count(u8, text.items, "\n"), records.len, text.items });
    return behaviour(arena, text.items);
}


const Runner = struct { arena: std.mem.Allocator, io: Io, zanity: []const u8 };
const Suite = struct { path: []const u8, dir: Io.Dir };
const Case = struct { name: []const u8, project: bool };

fn caseFailure(runner: Runner, suite: Suite, case: Case) !?[]const u8 {
    const name = case.name;
    const arena = runner.arena;
    const io = runner.io;
    const zanity = runner.zanity;
    if (!std.fs.path.isAbsolute(zanity)) assert.panic("the zanity binary path '{s}' is relative; golden cases run in other directories and need an absolute path", .{zanity});
    const stem = if (case.project) name else name[0 .. name.len - std.fs.path.extension(name).len];
    if (stem.len == 0) assert.panic("golden case '{s}' has no name before its extension; name the case file, such as case.py, not .py", .{name});
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

/// One golden case, run on its own thread with its own arena.
const GoldenRun = struct {
    runner: Runner,
    suite: Suite,
    suite_name: []const u8,
    case: Case,
    arena: std.heap.ArenaAllocator,
    slots: *Io.Semaphore,
    failure: ?[]const u8 = null,
    err: ?anyerror = null,

    fn checkCase(job: *GoldenRun) void {
        const case_name = job.case.name;
        if (case_name.len == 0) assert.panic("a golden case in {s} has no name; the suite's directory listing never gives empty names", .{job.suite_name});
        job.slots.waitUncancelable(job.runner.io);
        defer job.slots.post(job.runner.io);
        var runner = job.runner;
        runner.arena = job.arena.allocator();
        job.failure = caseFailure(runner, job.suite, job.case) catch |e| {
            job.err = e;
            return;
        };
        if (job.failure != null and job.err != null) assert.panic("{s}: the case both failed and errored; checkCase() records one or the other", .{job.case.name});
    }
};

test "golden cases reproduce the source tools' findings through the CLI" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var root = try Io.Dir.cwd().openDir(io, "tests/golden", .{ .iterate = true });
    defer root.close(io);
    var slots: Io.Semaphore = .{ .permits = std.Thread.getCpuCount() catch 4 };
    var jobs: std.ArrayList(GoldenRun) = .empty;
    var suites: std.ArrayList(Io.Dir) = .empty;
    defer for (suites.items) |suite| suite.close(io);
    var entries = root.iterate();
    while (try entries.next(io)) |suite_entry| {
        if (suite_entry.kind != .directory) continue;
        const suite_name = try arena.dupe(u8, suite_entry.name);
        const suite: Suite = .{ .path = try std.fmt.allocPrint(arena, "tests/golden/{s}", .{suite_name}), .dir = try root.openDir(io, suite_name, .{ .iterate = true }) };
        try suites.append(arena, suite.dir);
        var cases = suite.dir.iterate();
        while (try cases.next(io)) |case| {
            if (std.mem.endsWith(u8, case.name, ".expected")) continue;
            if (case.kind != .file and case.kind != .directory) continue;
            try jobs.append(arena, .{
                .runner = .{ .arena = arena, .io = io, .zanity = zanity },
                .suite = suite,
                .suite_name = suite_name,
                .case = .{ .name = try arena.dupe(u8, case.name), .project = case.kind == .directory },
                .arena = .init(std.heap.page_allocator),
                .slots = &slots,
            });
        }
    }
    defer for (jobs.items) |*job| job.arena.deinit();
    var group: Io.Group = .init;
    for (jobs.items) |*job| group.async(io, GoldenRun.checkCase, .{job});
    try group.await(io);
    var failures: usize = 0;
    for (jobs.items) |job| {
        if (job.err) |e| return e;
        const failure = job.failure orelse continue;
        failures += 1;
        std.debug.print("\n[{s}] {s}\n", .{ job.suite_name, failure });
    }
    if (failures > 0) std.debug.print("\n{d} of {d} golden cases failed\n", .{ failures, jobs.items.len });
    try std.testing.expect(jobs.items.len > 0);
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

test "zanity.schema.json matches the rules and settings in the code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rendered: std.Io.Writer.Allocating = .init(arena);
    try schema.renderSchema(&rendered.writer);
    const committed = try Io.Dir.cwd().readFileAlloc(std.testing.io, "zanity.schema.json", arena, .unlimited);
    std.testing.expectEqualStrings(rendered.written(), committed) catch |e| {
        std.debug.print("\nzanity.schema.json is out of date with the rules or settings; run zig build schema and commit the result\n", .{});
        return e;
    };
}

test "zanity init writes a zanity.toml that check reads, and won't overwrite it unasked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "vendor");
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "LIMIT = 3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/dep.py", .data = "def f(x):\n    return x\n" });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const first = try std.process.run(arena, io, .{ .argv = &.{ zanity, "init" }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, first.term);
    const written = try tmp.dir.readFileAlloc(io, "zanity.toml", arena, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, written, "#:schema " ++ schema.url));
    try std.testing.expect(std.mem.indexOf(u8, written, "exclude = [\"vendor/\"]") != null);
    const checked = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "." }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, checked.term);
    try std.testing.expectEqualStrings("zanity: checked 1 file, no issues found\n", checked.stderr);
    const again = try std.process.run(arena, io, .{ .argv = &.{ zanity, "init" }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, again.term);
    const forced = try std.process.run(arena, io, .{ .argv = &.{ zanity, "init", "--force" }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, forced.term);
}

test "--strict fails a run with only warnings, which a plain run passes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const fixture = "tests/golden/nasa/nasa02_detects_while_true.py";
    const plain = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "-q", "--rules", "unbounded-loop", fixture } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, plain.term);
    try std.testing.expectEqualStrings("zanity: 0 errors and 1 warning in 1 of 1 file\n", plain.stderr);
    const strict = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "-q", "--strict", "--rules", "unbounded-loop", fixture } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, strict.term);
}

/// Starts tests/infer/mock_typesafe.py and returns it with the port it listens on.
fn startMock(arena: std.mem.Allocator, io: Io, log: []const u8, env: *std.process.Environ.Map) !struct { child: std.process.Child, port: []const u8 } {
    if (log.len == 0) assert.panic("the mock TypeSafe server needs a log path to record requests in; pass a scratch path for the mock's log", .{});
    try env.put("MOCK_TYPESAFE_LOG", log);
    var child = try std.process.spawn(io, .{ .argv = &.{ "python3", "tests/infer/mock_typesafe.py" }, .stdout = .pipe, .environ_map = env });
    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const port = try reader.interface.takeDelimiterExclusive('\n');
    if (port.len == 0 or port.len > 5) assert.panic("the mock TypeSafe server printed '{s}' instead of a port; the mock must print its port first, so check tests/infer/mock_typesafe.py", .{port});
    return .{ .child = child, .port = try arena.dupe(u8, port) };
}

test "--infer asks each unit only its own questions, skips what checks settled, and caches every answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try tmp.dir.writeFile(io, .{ .sub_path = "service.py", .data = try Io.Dir.cwd().readFileAlloc(io, "tests/infer/project/service.py", arena, .unlimited) });
    try tmp.dir.writeFile(io, .{ .sub_path = "pyproject.toml", .data = "[tool.ruff]\nline-length = 200  # judge: weakened-check\n# judge: unscheduled-analysis\n" });
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
    for ([_][]const u8{ "rule=\"misleading-error\"", "rule=\"unconstructive-error\"", "'invalid input' doesn't say", "rule=\"hollow-test\"", "rule=\"weakened-check\"", "rule=\"unscheduled-analysis\"" }) |expected| {
        if (std.mem.indexOf(u8, outputs[0], expected) == null) std.debug.print("\nmissing {s} in:\n{s}", .{ expected, outputs[0] });
        try std.testing.expect(std.mem.indexOf(u8, outputs[0], expected) != null);
    }
    const requests = try tmp.dir.readFileAlloc(io, "requests.log", arena, .unlimited);
    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, requests, "\n"));
    var lines = std.mem.tokenizeScalar(u8, requests, '\n');
    while (lines.next()) |line| {
        const fine = std.mem.indexOf(u8, line, "def fine") != null;
        const is_test = std.mem.indexOf(u8, line, "def test_") != null;
        const errors = std.mem.indexOf(u8, line, "vague-error") != null;
        if (fine or is_test) try std.testing.expect(!errors);
        if (is_test) try std.testing.expect(std.mem.indexOf(u8, line, "name-behaviour-mismatch") == null);
        if (!is_test) try std.testing.expect(std.mem.indexOf(u8, line, "hollow-test") == null);
        if (std.mem.indexOf(u8, line, "def test_waits") != null) try std.testing.expect(std.mem.indexOf(u8, line, "flaky-test") == null);
        const config_line = std.mem.indexOf(u8, line, "weakened-check") != null or std.mem.indexOf(u8, line, "unscheduled-analysis") != null;
        if (config_line) try std.testing.expect(std.mem.indexOf(u8, line, "name-behaviour-mismatch") == null);
    }
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
