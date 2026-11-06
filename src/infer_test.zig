//! End-to-end tests of `--infer` against tests/infer/mock_typesafe.py: which questions are
//! asked, what is kept between runs, and what a failed, refused or interrupted request leaves.
const std = @import("std");
const assert = @import("assert.zig");
const golden = @import("golden_test.zig");
const behaviour = golden.behaviour;
const expectOutput = golden.expectOutput;
const exited = golden.exited;
const paths = @import("paths");

const Io = std.Io;

/// tests/infer/mock_typesafe.py, running, and the environment that points zanity at it and at a
/// store of its own.
const MockTypeSafe = struct { child: std.process.Child, env: std.process.Environ.Map };

/// Starts the mock, logging requests to requests.log and keeping the store in `dir`.
fn startMock(arena: std.mem.Allocator, io: Io, dir: []const u8) !MockTypeSafe {
    if (!std.fs.path.isAbsolute(dir)) assert.panic("the mock's directory '{s}' is relative; pass an absolute path, since zanity runs in another directory", .{dir});
    var env = std.process.Environ.Map.init(arena);
    try env.put("MOCK_TYPESAFE_LOG", try std.fs.path.join(arena, &.{ dir, "requests.log" }));
    try env.put("MOCK_TYPESAFE_HANG", try std.fs.path.join(arena, &.{ dir, "hang" }));
    var child = try std.process.spawn(io, .{ .argv = &.{ "python3", "tests/infer/mock_typesafe.py" }, .stdin = .pipe, .stdout = .pipe, .environ_map = &env });
    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const port = try reader.interface.takeDelimiterExclusive('\n');
    if (port.len == 0 or port.len > 5) assert.panic("the mock TypeSafe server printed '{s}' instead of a port; the mock must print its port first, so check tests/infer/mock_typesafe.py", .{port});
    try env.put("TYPESAFE_API_KEY", "test");
    try env.put("ZANITY_STORE", try std.fs.path.join(arena, &.{ dir, "store.db" }));
    try env.put("TYPESAFE_BASE_URL", try std.fmt.allocPrint(arena, "http://127.0.0.1:{s}", .{port}));
    return .{ .child = child, .env = env };
}

/// Writes the project the --infer test checks into `scratch`, the test's temporary directory, which
/// the test deletes when it ends: Python functions and tests, a Zig file that only gathers tests,
/// a pyproject.toml with a weakened check and a zanity.toml that sets nothing.
fn writeInferProject(arena: std.mem.Allocator, io: Io, scratch: Io.Dir) !void {
    const service = try Io.Dir.cwd().readFileAlloc(io, "tests/infer/project/service.py", arena, .unlimited);
    const support = try Io.Dir.cwd().readFileAlloc(io, "tests/infer/project/test_support.py", arena, .unlimited);
    if (service.len == 0) assert.panic("tests/infer/project/service.py is empty; restore it from git", .{});
    if (support.len == 0) assert.panic("tests/infer/project/test_support.py is empty; restore it from git", .{});
    if (std.mem.indexOf(u8, service, "# judge: ") == null) assert.panic("tests/infer/project/service.py marks no rule with '# judge: <rule>', so the mock would answer no to everything; restore the markers", .{});
    if (std.mem.indexOf(u8, support, "# judge: fixture-") == null) assert.panic("tests/infer/project/test_support.py marks no fixture rule, so the mock would answer no to both fixture questions; restore the markers", .{});
    try scratch.writeFile(io, .{ .sub_path = "service.py", .data = service });
    try scratch.writeFile(io, .{ .sub_path = "test_support.py", .data = support });
    try scratch.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{\n  \"compilerOptions\": {\n    \"strict\": true\n  }\n}\n" });
    try scratch.writeFile(io, .{ .sub_path = "all_test.zig", .data = "test {\n    _ = @import(\"service_test.zig\");\n}\n" });
    try scratch.writeFile(io, .{ .sub_path = "pyproject.toml", .data = "[tool.ruff]\nline-length = 200  # judge: weakened-check\n# judge: unscheduled-analysis\n" });
    // The project sits under this repository's .zig-cache, so without a zanity.toml of its own it
    // would take the repository's, whose [infer] url names a local server instead of the mock.
    try scratch.writeFile(io, .{ .sub_path = "zanity.toml", .data = "# The mock project's own settings: none.\n" });
}

/// writeInferProject's project in a temporary directory, and the mock TypeSafe it asks.
pub const InferRun = struct {
    tmp: std.testing.TmpDir,
    mock: MockTypeSafe,
    work: []const u8,
    zanity: []const u8,

    pub fn initInferRun(arena: std.mem.Allocator, io: Io) !InferRun {
        var tmp = std.testing.tmpDir(.{});
        const work = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        try writeInferProject(arena, io, tmp.dir);
        const mock = try startMock(arena, io, try Io.Dir.cwd().realPathFileAlloc(io, work, arena));
        if (work.len == 0) assert.panic("the --infer project has no directory; tmpDir() names one under .zig-cache/tmp", .{});
        const zanity = try Io.Dir.cwd().realPathFileAlloc(io, paths.zanity, arena);
        if (!std.fs.path.isAbsolute(zanity)) assert.panic("zanity resolved to the relative path '{s}'; the project runs it from another directory, so it needs an absolute one", .{zanity});
        return .{ .tmp = tmp, .mock = mock, .work = work, .zanity = zanity };
    }

    /// Runs zanity check --infer --plain on the project.
    pub fn checkInferring(self: *InferRun, arena: std.mem.Allocator, io: Io) !std.process.RunResult {
        const run = try std.process.run(arena, io, .{ .argv = &.{ self.zanity, "check", ".", "--infer", "--plain" }, .cwd = .{ .path = self.work }, .environ_map = &self.mock.env });
        if (self.work.len == 0) assert.panic("running --infer on a project with no directory; initInferRun() sets it", .{});
        if (!std.fs.path.isAbsolute(self.zanity)) assert.panic("running zanity at the relative path '{s}' from {s}; initInferRun() resolves it", .{ self.zanity, self.work });
        return exited(run, "zanity check --infer");
    }
};

test "--infer keeps every answer, so a second run asks the model nothing and reports the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var project = try InferRun.initInferRun(arena, std.testing.io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(std.testing.io);
    const first = try project.checkInferring(arena, std.testing.io);
    const second = try project.checkInferring(arena, std.testing.io);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
    try expectOutput(first.stderr, &.{}, &.{", 0 asked of jev-latest"});
    try expectOutput(second.stderr, &.{", 0 asked of jev-latest"}, &.{});
    const requests = try project.tmp.dir.readFileAlloc(std.testing.io, "requests.log", arena, .unlimited);
    try expectOutput(requests, &.{"\"authorization\": \"Bearer test\""}, &.{});
}

test "--infer names a unit too large to send and keeps every other answer, but stops on a refused key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try InferRun.initInferRun(arena, io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(io);
    const whole = try project.checkInferring(arena, io);
    try project.tmp.dir.writeFile(io, .{ .sub_path = "huge.py", .data = "def huge():\n    # mock: too-large\n    return 1\n" });
    const huge = try project.checkInferring(arena, io);
    try std.testing.expectEqual(whole.term, huge.term);
    try std.testing.expectEqual(std.mem.count(u8, whole.stdout, "(jev-latest is"), std.mem.count(u8, huge.stdout, "(jev-latest is"));
    try expectOutput(huge.stdout, &.{"(jev-latest is 95% sure)"}, &.{});
    try expectOutput(huge.stderr, &.{ "zanity: jev-latest refused 'huge' in huge.py as too large for one request", "so its questions were not asked; split it" }, &.{"could not judge"});
    try project.tmp.dir.writeFile(io, .{ .sub_path = "locked.py", .data = "def locked():\n    # mock: unauthorized\n    return 1\n" });
    const locked = try project.checkInferring(arena, io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 74 }, locked.term);
    try expectOutput(locked.stderr, &.{ "could not judge", "Unauthorized (HTTP 401", "Check the API key in TYPESAFE_API_KEY" }, &.{"Check TYPESAFE_BASE_URL"});
}

test "--infer keeps the answers it got before a request failed, so the next run asks only what is left" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try InferRun.initInferRun(arena, io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(io);
    try project.tmp.dir.writeFile(io, .{ .sub_path = "locked.py", .data = "def locked():\n    # mock: unauthorized\n    return 1\n" });
    const locked = try project.checkInferring(arena, io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 74 }, locked.term);
    try project.tmp.dir.deleteFile(io, "locked.py");
    const resumed = try project.checkInferring(arena, io);
    try expectOutput(resumed.stderr, &.{", 0 asked of jev-latest"}, &.{});
}

test "--infer keeps each answer as it arrives, so a run stopped mid-way never asks for them again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try InferRun.initInferRun(arena, io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(io);
    // One request at a time, so every answer sent before the hanging request is already stored.
    try project.tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data = "[infer]\nconcurrency = 1\n" });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "hang", .data = std.fmt.comptimePrint("{d}", .{answered_before_hang + 1}) });
    var stopped = try std.process.spawn(io, .{ .argv = &.{ project.zanity, "check", ".", "--infer", "--plain" }, .cwd = .{ .path = project.work }, .environ_map = &project.mock.env, .stdout = .ignore, .stderr = .ignore });
    defer stopped.kill(io);
    var before: []const u8 = "";
    for (0..max_hang_polls) |_| {
        before = project.tmp.dir.readFileAlloc(io, "requests.log", arena, .unlimited) catch "";
        if (std.mem.count(u8, before, "\n") > answered_before_hang) break;
        try io.sleep(.fromMilliseconds(hang_poll_ms), .awake);
    } else return error.HangingRequestNeverSent;
    stopped.kill(io);
    try project.tmp.dir.deleteFile(io, "hang");
    try project.tmp.dir.deleteFile(io, "requests.log");
    _ = try project.checkInferring(arena, io);
    const after = project.tmp.dir.readFileAlloc(io, "requests.log", arena, .unlimited) catch "";
    var lines = std.mem.splitScalar(u8, before, '\n');
    for (0..answered_before_hang) |_| try expectOutput(after, &.{}, &.{lines.next().?});
}

/// Requests the mock answers before it leaves one hanging, in the stopped-run test.
const answered_before_hang = 2;
/// How long the stopped-run test waits for zanity to send the request the mock never answers.
const hang_poll_ms = 50;
const max_hang_polls = 600;

test "--infer asks the System One server zanity.toml names, with only the key it names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try InferRun.initInferRun(arena, io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(io);
    const url = project.mock.env.get("TYPESAFE_BASE_URL") orelse assert.panic("startMock() set no TYPESAFE_BASE_URL", .{});
    try project.tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data = try std.fmt.allocPrint(arena, "[infer]\nurl = \"{s}\"\nmodel = \"kev-latest\"\napi_key_env = \"KEV_API_KEY\"\n", .{url}) });
    const keyless = try project.checkInferring(arena, io);
    try expectOutput(keyless.stdout, &.{"(kev-latest is 95% sure)"}, &.{});
    const requests = try project.tmp.dir.readFileAlloc(io, "requests.log", arena, .unlimited);
    try expectOutput(requests, &.{"\"model\": \"kev-latest\""}, &.{"Bearer"});
    try project.mock.env.put("KEV_API_KEY", "local");
    try project.tmp.dir.deleteFile(io, "requests.log");
    try project.tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data = try std.fmt.allocPrint(arena, "[infer]\nurl = \"{s}\"\nmodel = \"kev-4b\"\napi_key_env = \"KEV_API_KEY\"\n", .{url}) });
    _ = try project.checkInferring(arena, io);
    const keyed = try project.tmp.dir.readFileAlloc(io, "requests.log", arena, .unlimited);
    try expectOutput(keyed, &.{"\"authorization\": \"Bearer local\""}, &.{"Bearer test"});
}

test "--infer reports what the model is sure of, for functions, fixtures, tests and project files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var project = try InferRun.initInferRun(arena, std.testing.io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(std.testing.io);
    const run = try project.checkInferring(arena, std.testing.io);
    try expectOutput(run.stdout, &.{ "rule=\"misleading-error\"", "rule=\"unconstructive-error\"", "'invalid input' doesn't say", "rule=\"hollow-test\"", "rule=\"fixture-leaks-state\"", "rule=\"fixture-hides-behaviour\"", "rule=\"weakened-check\"", "rule=\"unscheduled-analysis\"", "rule=\"repeated-mechanics\"", "between the first two, `\\\"alpha beta\\\"` becomes `\\\"ada lovelace\\\"`" }, &.{});
}

test "--infer asks zanity.toml's own questions, and holds a retuned one to its own threshold" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try InferRun.initInferRun(arena, io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(io);
    try project.tmp.dir.writeFile(io, .{ .sub_path = "zanity.toml", .data =
        \\[questions."payment-without-key"]
        \\question = "Does the function charge a card without an idempotency key?"
        \\finding = "A card is charged without an idempotency key"
        \\fix = "Pass the order's id as the payment's idempotency key."
        \\severity = "error"
        \\
        \\[questions."misleading-error"]
        \\threshold = 0.99
        \\
    });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "pay.py", .data = "def charge(card, amount):\n    # judge: payment-without-key\n    return card.charge(amount)\n" });
    const run = try project.checkInferring(arena, io);
    // The mock is 95% sure of every marked question: enough for the new one, short of the retuned 0.99.
    try expectOutput(run.stdout, &.{ "rule=\"payment-without-key\"", "severity=\"error\"", "In 'charge': A card is charged without an idempotency key" }, &.{"rule=\"misleading-error\""});
}

test "zanity mark --not-a-problem stops --infer reporting that finding for that function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var project = try InferRun.initInferRun(arena, io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(io);
    const first = try project.checkInferring(arena, io);
    const at = std.mem.indexOf(u8, first.stdout, "rule=\"misleading-error\"") orelse return error.TestExpectedFinding;
    const record = first.stdout[(std.mem.lastIndexOfScalar(u8, first.stdout[0..at], '\n') orelse 0)..at];
    const path = between(record, "path=\"", "\"") orelse return error.TestExpectedPath;
    const line = between(record, "line=", "\t") orelse return error.TestExpectedLine;
    const place = try std.fmt.allocPrint(arena, "{s}:{s}", .{ path, line });
    const marked = try std.process.run(arena, io, .{ .argv = &.{ project.zanity, "mark", place, "misleading-error", "--not-a-problem", "--plain" }, .cwd = .{ .path = project.work }, .environ_map = &project.mock.env });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, marked.term);
    try expectOutput(marked.stdout, &.{"real=false"}, &.{});
    const second = try project.checkInferring(arena, io);
    try expectOutput(second.stdout, &.{}, &.{"rule=\"misleading-error\""});
    const stats = try std.process.run(arena, io, .{ .argv = &.{ project.zanity, "stats", "--rule", "misleading-error", "--plain" }, .cwd = .{ .path = project.work }, .environ_map = &project.mock.env });
    try expectOutput(stats.stdout, &.{"not_a_problem=1"}, &.{});
}

/// The text after `start` up to `end` in `record`.
fn between(record: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    if (start.len == 0 or end.len == 0) assert.panic("looking between an empty marker in '{s}'; pass non-empty markers to between()", .{record});
    const from = (std.mem.indexOf(u8, record, start) orelse return null) + start.len;
    const to = std.mem.indexOfPos(u8, record, from, end) orelse return null;
    if (to < from) assert.panic("found '{s}' at {d}, before the text it ends, at {d}; search for the closing marker after the opening one", .{ end, to, from });
    return record[from..to];
}

test "--infer asks each unit only its own questions and skips what checks settled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var project = try InferRun.initInferRun(arena, std.testing.io);
    defer project.tmp.cleanup();
    defer project.mock.child.kill(std.testing.io);
    _ = try project.checkInferring(arena, std.testing.io);
    const requests = try project.tmp.dir.readFileAlloc(std.testing.io, "requests.log", arena, .unlimited);
    // Sixteen functions, tests, fixtures, settings and the project, each asked at least once; a
    // unit with more questions than one request carries is asked in several.
    try std.testing.expect(std.mem.count(u8, requests, "\n") >= 16);
    // Every request a unit needed, joined, keyed by the unit's first line.
    var asked: std.StringArrayHashMapUnmanaged(std.ArrayList(u8)) = .empty;
    var requested = std.mem.tokenizeScalar(u8, requests, '\n');
    while (requested.next()) |request| {
        const logged = try std.json.parseFromSliceLeaky(struct { function: []const u8, questions: []const []const u8 }, arena, request, .{ .ignore_unknown_fields = true });
        try std.testing.expect(logged.questions.len > 0 and logged.questions.len <= 64);
        const entry = try asked.getOrPut(arena, logged.function);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(arena, request);
    }
    for (asked.values()) |joined| {
        const line = joined.items;
        const fine = std.mem.indexOf(u8, line, "def fine") != null;
        const is_test = std.mem.indexOf(u8, line, "def test_") != null;
        const is_fixture = std.mem.indexOf(u8, line, "@pytest.fixture") != null;
        if (fine or is_test) try expectOutput(line, &.{}, &.{"vague-error"});
        if (is_test) try expectOutput(line, &.{}, &.{"name-behaviour-mismatch"});
        if (!is_test) try expectOutput(line, &.{}, &.{"hollow-test"});
        if (is_fixture) try expectOutput(line, &.{ "fixture-leaks-state", "fixture-hides-behaviour", "name-behaviour-mismatch" }, &.{"hollow-test"});
        if (!is_fixture) try expectOutput(line, &.{}, &.{ "fixture-leaks-state", "fixture-hides-behaviour" });
        if (std.mem.indexOf(u8, line, "def test_waits") != null) try expectOutput(line, &.{}, &.{"flaky-test"});
        if (std.mem.indexOf(u8, line, "\"=== ") != null) try expectOutput(line, &.{"\"questions\": [\"repeated-mechanics\"]"}, &.{});
        const config_line = std.mem.indexOf(u8, line, "weakened-check") != null or std.mem.indexOf(u8, line, "unscheduled-analysis") != null;
        if (config_line) try expectOutput(line, &.{}, &.{"name-behaviour-mismatch"});
    }
}
