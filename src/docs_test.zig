//! Keeps docs/content/test-checks.smd listing exactly the rules that check tests, as
//! src/rules.zig defines them: every rule marked .tests or asked of tests and fixtures has one
//! row with its severity, and no other rule has a row.
const std = @import("std");
const assert = @import("assert.zig");
const rules = @import("rules.zig");

fn checksTests(rule: rules.Rule) bool {
    if (rule.name.len == 0) assert.panic("a rule in rules.all has no name (advice: '{s}'); give every entry in rules.all a .name", .{rule.advice});
    if (rule.tests and rule.question.len > 0) assert.panic("rule {s} is marked .tests and has an --infer question; .tests marks the rules found in the code, and the question's .asks already says it checks tests", .{rule.name});
    return rule.tests or (rule.question.len > 0 and (rule.asks == .@"test" or rule.asks == .fixture));
}

fn rowName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "| `")) return null;
    const end = std.mem.indexOfScalarPos(u8, line, 3, '`') orelse assert.panic("the table row '{s}' opens a rule name it never closes; run python3 docs/sync.py", .{line});
    if (end == 3) assert.panic("the table row '{s}' has an empty rule name; run python3 docs/sync.py", .{line});
    if (std.mem.indexOfAny(u8, line[3..end], " |") != null) assert.panic("the table row '{s}' has a rule name with a space or bar in it; run python3 docs/sync.py", .{line});
    return line[3..end];
}

test "the test checks page has one row for each rule that checks tests, and no other" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const page = try std.Io.Dir.cwd().readFileAlloc(io, "docs/content/test-checks.smd", arena, .unlimited);
    var problems: usize = 0;
    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, page, '\n');
    while (lines.next()) |line| {
        const name = rowName(line) orelse continue;
        rows += 1;
        const rule = rules.find(name) orelse {
            std.debug.print("\ndocs/content/test-checks.smd lists {s}, which zanity does not have; run python3 docs/sync.py", .{name});
            problems += 1;
            continue;
        };
        if (!checksTests(rule)) {
            std.debug.print("\ndocs/content/test-checks.smd lists {s}, which does not check tests; mark it .tests in src/rules.zig, or run python3 docs/sync.py", .{name});
            problems += 1;
        }
        const severity = try std.fmt.allocPrint(arena, "| {s}, ", .{@tagName(rule.severity)});
        if (std.mem.indexOf(u8, line, severity) == null) {
            std.debug.print("\ndocs/content/test-checks.smd does not give {s} its severity, {s}; run python3 docs/sync.py", .{ name, @tagName(rule.severity) });
            problems += 1;
        }
    }
    var expected: usize = 0;
    for (rules.all) |rule| {
        if (!checksTests(rule)) continue;
        expected += 1;
        const row = try std.fmt.allocPrint(arena, "\n| `{s}` |", .{rule.name});
        const count = std.mem.count(u8, page, row);
        if (count != 1) {
            std.debug.print("\ndocs/content/test-checks.smd has {d} rows for {s}, which checks tests; run python3 docs/sync.py", .{ count, rule.name });
            problems += 1;
        }
    }
    if (expected == 0) assert.panic("no rule in src/rules.zig checks tests; mark the rules that do .tests = true", .{});
    try std.testing.expectEqual(expected, rows);
    try std.testing.expectEqual(@as(usize, 0), problems);
}
