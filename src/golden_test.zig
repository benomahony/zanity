const std = @import("std");
const assert = @import("assert.zig");
const strings = @import("strings.zig");
const paths = @import("paths");
const rules = @import("rules.zig");
const schema = @import("schema.zig");
const infer_test = @import("infer_test.zig");

const Io = std.Io;

pub fn behaviour(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
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
    const dirty = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--rules", "assertion-density,long-parameter-list", "shapes.py", "shapes_zig.zig" }, .cwd = .{ .path = "tests/golden/structure" } });
    try std.testing.expectEqualStrings("zanity: 15 errors and 3 warnings in 2 of 2 files\n", dirty.stderr);
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

/// Runs zanity check on a one-file project with `environ` and `flags`.
/// Fails unless `output` holds every text in `has` and none in `lacks`, printing each text out of
/// place and then the output, so a failure shows what was there instead.
pub fn expectOutput(output: []const u8, has: []const []const u8, lacks: []const []const u8) !void {
    if (has.len + lacks.len == 0) assert.panic("expectOutput() was given no text to look for, so it checks nothing; pass the texts the output must have or lack", .{});
    var misses: usize = 0;
    for (has) |text| {
        if (text.len == 0) assert.panic("expectOutput() was asked for empty text, which every output holds; pass the text the output must have", .{});
        if (std.mem.indexOf(u8, output, text) != null) continue;
        std.debug.print("\nmissing: {s}", .{text});
        misses += 1;
    }
    for (lacks) |text| {
        if (text.len == 0) assert.panic("expectOutput() was asked to rule out empty text, which every output holds; pass the text the output must lack", .{});
        const at = std.mem.indexOf(u8, output, text) orelse continue;
        std.debug.print("\nunexpected at byte {d}: {s}", .{ at, text });
        misses += 1;
    }
    if (misses == 0) return;
    std.debug.print("\nin:\n{s}\n", .{output});
    return error.TestUnexpectedOutput;
}

test "zanity init writes a zanity.toml that check reads, with [rules] last, and won't overwrite it unasked" {
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
    try expectOutput(written, &.{"exclude = [\"vendor/\"]"}, &.{});
    const checked = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "." }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, checked.term);
    try std.testing.expectEqualStrings("zanity: checked 1 file, skipped 1 file, no issues found\n", checked.stderr);
    const again = try std.process.run(arena, io, .{ .argv = &.{ zanity, "init" }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, again.term);
    const forced = try std.process.run(arena, io, .{ .argv = &.{ zanity, "init", "--force" }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, forced.term);
    const full = try tmp.dir.readFileAlloc(io, "zanity.toml", arena, .unlimited);
    const table = std.mem.indexOf(u8, full, "\n[rules]\n") orelse return error.NoRulesTable;
    try expectOutput(full[table + 1 ..], &.{}, &.{"\n["});
}

test "zanity init --minimal writes only the settings, which check reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "vendor");
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "LIMIT = 3\n" });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const minimal = try std.process.run(arena, io, .{ .argv = &.{ zanity, "init", "--minimal" }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, minimal.term);
    try std.testing.expectEqualStrings("#:schema " ++ schema.url ++ "\nexclude = [\"vendor/\"]\n\n[rules]\nselect = [\"all\"]\ndisable = []\n", try tmp.dir.readFileAlloc(io, "zanity.toml", arena, .unlimited));
    const checked = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "." }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, checked.term);
}

test "--fail-on warning fails a run with only warnings, which a plain run passes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const fixture = "tests/golden/nasa/nasa02_detects_while_true.py";
    const plain = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "-q", "--rules", "unbounded-loop", fixture } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, plain.term);
    try std.testing.expectEqualStrings("zanity: 0 errors and 1 warning in 1 of 1 file\n", plain.stderr);
    const failing = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "-q", "--fail-on", "warning", "--rules", "unbounded-loop", fixture } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failing.term);
}

test "--strict runs the strict rules, which a plain run leaves off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "spin.py", .data = "def spin():\n    while True:\n        pass\n" });
    const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const plain = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "-q", "--plain", "." }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, plain.stdout, "rule=\"unbounded-loop\""));
    const strict = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "-q", "--plain", "--strict", "." }, .cwd = .{ .path = work } });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, strict.stdout, "rule=\"unbounded-loop\""));
}

/// `run`, when zanity exited and reported something; otherwise zanity's output, printed, and a test
/// error, so the test's cleanup, such as stopping the mock TypeSafe, still runs.
pub fn exited(run: std.process.RunResult, what: []const u8) !std.process.RunResult {
    if (what.len == 0) assert.panic("checking how an unnamed command ended; name it for the failure message", .{});
    if (std.mem.indexOfScalar(u8, what, '\n') != null) assert.panic("the command's name '{s}' spans lines; name it on one line, as the failure message prints it inline", .{what});
    if (run.term == .exited and run.stdout.len + run.stderr.len > 0) return run;
    std.debug.print("\n{s} ended with {any} instead of exiting with a report; its output:\n{s}\n{s}\n", .{ what, run.term, run.stdout, run.stderr });
    return error.ZanityDidNotExit;
}

test "zanity.toml disables rules and excludes paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--plain", "." }, .cwd = .{ .path = "tests/config/project" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, run.term);
    try expectOutput(run.stdout, &.{}, &.{ "long-parameter-list", "vendor/" });
    try std.testing.expectEqualStrings("zanity: checked 1 file, skipped 1 file, no issues found\n", run.stderr);
}

test "a mistake in zanity.toml stops the run and says where" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const run = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", "--plain", "." }, .cwd = .{ .path = "tests/config/broken" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, run.term);
    try expectOutput(run.stderr, &.{"zanity.toml:1: 'recursions' isn't a rule"}, &.{});
}

test {
    _ = @import("baseline_test.zig");
    _ = infer_test;
    _ = @import("lsp_test.zig");
    _ = @import("fix_test.zig");
    _ = @import("agent_test.zig");
}

test "slow-test uses measured JUnit durations without inference and honors the time budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
    const source = "tests/golden/tests/test_constant_assertion.py";
    const measured = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", source, "--rules", "slow-test", "--junit", "tests/timings/junit.xml", "--fail-on", "warning", "--json" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, measured.term);
    try std.testing.expectEqualStrings("tests/timings/junit.xml:4:1: warning [slow-test]\n", try behaviourOfJson(arena, measured.stdout));
    try std.testing.expect(std.mem.indexOf(u8, measured.stdout, "2.500 seconds") != null);
    const relaxed = try std.process.run(arena, io, .{ .argv = &.{ zanity, "check", source, "--rules", "slow-test", "--junit", "tests/timings/junit.xml", "--slow-test-ms", "2500", "--fail-on", "warning", "--json" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, relaxed.term);
    try std.testing.expectEqualStrings("", try behaviourOfJson(arena, relaxed.stdout));
}
