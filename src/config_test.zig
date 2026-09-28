const std = @import("std");
const config = @import("config.zig");

fn parsed(arena: std.mem.Allocator, text: []const u8) !config.Config {
    if (text.len == 0) std.debug.panic("parsing an empty test config; pass the TOML under test", .{});
    const result = try config.parseConfig(try arena.dupe(u8, text));
    if (result.exclude_len > config.max_excludes) std.debug.panic("parsed {d} exclude patterns in room for {d}", .{ result.exclude_len, config.max_excludes });
    return result;
}

fn expectProblem(text: []const u8, expected: []const u8) !void {
    if (!std.mem.startsWith(u8, expected, config.file_name)) std.debug.panic("expected problem '{s}' should start with the file name", .{expected});
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidConfig, parsed(arena_state.allocator(), text));
    try std.testing.expectEqualStrings(expected, config.problem[0..config.problem_len]);
    if (config.problem_len == 0) std.debug.panic("the problem for '{s}' is empty", .{text});
}

test "a zanity.toml chooses rules, excludes paths and sets concurrency" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(),
        \\# which rules run
        \\rules = ["recursion", "long-function", 'NASA02']
        \\exclude = [
        \\    "vendor/",   # third-party
        \\    "tests/golden/**",
        \\]
        \\
        \\[infer]
        \\concurrency = 1_6
        \\
    );
    try std.testing.expect(c.rules.?.enabled("recursion"));
    try std.testing.expect(c.rules.?.enabled("unbounded-loop"));
    try std.testing.expect(!c.rules.?.enabled("duplicate-name"));
    try std.testing.expectEqual(@as(usize, 2), c.exclude_len);
    try std.testing.expectEqualStrings("tests/golden/**", c.exclude[1]);
    try std.testing.expectEqual(@as(?u32, 16), c.concurrency);
}

test "disable removes rules from the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "disable = [\"duplicate-name\", \"name-drift\"]\n");
    const chosen = c.selection();
    try std.testing.expect(!chosen.enabled("duplicate-name"));
    try std.testing.expect(!chosen.enabled("name-drift"));
    try std.testing.expect(chosen.enabled("recursion"));
}

test "mistakes in zanity.toml name the line and what to write" {
    try expectProblem("rules = [\"recursions\"]\n", "zanity.toml:1: 'recursions' isn't a rule; the rules are listed in the README, and 'zanity check --rules' takes the same names.");
    try expectProblem("\ndisabled = []\n", "zanity.toml:2: 'disabled' isn't a setting; the settings are rules, disable, exclude and, under [infer], concurrency.");
    try expectProblem("[inference]\n", "zanity.toml:1: '[inference]' isn't a table zanity knows; the only table is [infer].");
    try expectProblem("[infer]\nconcurrency = 500\n", "zanity.toml:2: concurrency is 500; it must be between 1 and 64.");
    try expectProblem("rules = []\n", "zanity.toml:1: 'rules' is empty, so nothing would run; list at least one rule, or remove it to run the defaults.");
    try expectProblem("exclude = [\"a\" \"b\"]\n", "zanity.toml:1: items in 'exclude' must be separated by commas.");
    try expectProblem("rules = [\"recursion\"] extra\n", "zanity.toml:1: unexpected 'e' after a value; put each setting on its own line.");
}
