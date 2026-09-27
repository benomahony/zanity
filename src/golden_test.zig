const std = @import("std");
const paths = @import("paths");
const rules = @import("rules.zig");
const assert = std.debug.assert;

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
    assert(findings.items.len == std.mem.count(u8, std.mem.trim(u8, output, "\n"), "\n") + @intFromBool(output.len > 0));
    std.mem.sort([]const u8, findings.items, {}, lineOrder);
    const joined = try std.mem.concat(arena, u8, findings.items);
    assert(joined.len >= findings.items.len);
    return joined;
}

const Record = struct { path: []const u8, line: u32, column: u32, severity: []const u8, rule: []const u8 };

/// zanity's `--json` records in the same normalised form as the expected files.
fn behaviourOfJson(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const records = try std.json.parseFromSliceLeaky([]const Record, arena, output, .{ .ignore_unknown_fields = true });
    var text: std.ArrayList(u8) = .empty;
    for (records) |r| {
        const rule = rules.find(r.rule) orelse return error.UnknownRule;
        assert(r.line >= 1 and r.column >= 1);
        try text.print(arena, "{s}:{d}:{d}: {s} [{s}]\n", .{ r.path, r.line, r.column, r.severity, rule.name });
    }
    assert(std.mem.count(u8, text.items, "\n") == records.len);
    return behaviour(arena, text.items);
}

fn lineOrder(_: void, a: []const u8, b: []const u8) bool {
    assert(a.len > 0);
    assert(b.len > 0);
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
    assert(std.fs.path.isAbsolute(zanity));
    const stem = if (case.project) name else name[0 .. name.len - std.fs.path.extension(name).len];
    assert(stem.len > 0);
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
