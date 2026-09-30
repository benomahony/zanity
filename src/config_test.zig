const std = @import("std");
const config = @import("config.zig");
const rules = @import("rules.zig");

fn parsed(arena: std.mem.Allocator, text: []const u8) !config.Config {
    if (text.len == 0) std.debug.panic("parsing an empty test config; pass the TOML under test", .{});
    const result = try config.parseConfig(try arena.dupe(u8, text));
    if (result.exclude_len > config.max_excludes) std.debug.panic("parsed {d} exclude patterns in room for {d}; parseConfig() must refuse lists longer than max_excludes", .{ result.exclude_len, config.max_excludes });
    return result;
}

fn expectProblem(text: []const u8, expected: []const u8) !void {
    if (!std.mem.startsWith(u8, expected, config.file_name)) std.debug.panic("expected problem '{s}' should start with the file name; start the expected problem with zanity.toml:<line>:", .{expected});
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidConfig, parsed(arena_state.allocator(), text));
    try std.testing.expectEqualStrings(expected, config.problem[0..config.problem_len]);
    if (config.problem_len == 0) std.debug.panic("the problem for '{s}' is empty; fail() must record a description of the problem", .{text});
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
        \\threshold = 0.95
        \\
    );
    try std.testing.expect(c.rules.?.enabled("recursion"));
    try std.testing.expect(c.rules.?.enabled("unbounded-loop"));
    try std.testing.expect(!c.rules.?.enabled("duplicate-name"));
    try std.testing.expectEqual(@as(usize, 2), c.exclude_len);
    try std.testing.expectEqualStrings("tests/golden/**", c.exclude[1]);
    try std.testing.expectEqual(@as(?u32, 16), c.concurrency);
    try std.testing.expectEqual(@as(?f64, 0.95), c.threshold);
}

test "'all' enables every rule, including those off by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "rules = [\"all\"]\ndisable = [\"long-file\"]\n");
    const chosen = c.selection();
    try std.testing.expect(chosen.enabled("restated-type"));
    try std.testing.expect(chosen.enabled("wide-scope"));
    try std.testing.expect(!chosen.enabled("long-file"));
    try std.testing.expectEqual(rules.all.len - 1, chosen.len);
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
    try expectProblem("rules = [\"recursions\"]\n", "zanity.toml:1: 'recursions' isn't a rule; the rules are listed in the README, 'all' names every rule, and 'zanity check --rules' takes the same names.");
    try expectProblem("\ndisabled = []\n", "zanity.toml:2: 'disabled' isn't a setting; the settings are rules, disable, exclude and, under [infer], concurrency and threshold.");
    try expectProblem("[inference]\n", "zanity.toml:1: '[inference]' isn't a table zanity knows; the tables are [infer] and [paths.\"<pattern>\"].");
    try expectProblem("[paths]\n", "zanity.toml:1: '[paths]' needs a pattern for the files it covers, such as [paths.\"tests/**\"].");
    try expectProblem("[paths.\"\"]\n", "zanity.toml:1: a [paths] pattern is empty; name the files it covers, such as \"tests/**\".");
    try expectProblem("[paths.\"tests/\"]\nrules = [\"recursion\"]\n", "zanity.toml:2: 'rules' isn't a [paths] setting; the only one is disable.");
    try expectProblem("[infer]\nconcurrency = 500\n", "zanity.toml:2: concurrency is 500; it must be between 1 and 64.");
    try expectProblem("[infer]\nthreshold = 1.5\n", "zanity.toml:2: threshold is 1.5; it must be above 0 and at most 1, such as 0.9 to report only what TypeSafe is at least 90% sure of.");
    try expectProblem("[infer]\nthreshold = high\n", "zanity.toml:2: 'threshold' needs a number, such as threshold = 0.9.");
    try expectProblem("[infer]\nmodel = \"x\"\n", "zanity.toml:2: 'model' isn't an [infer] setting; the settings are concurrency and threshold.");
    try expectProblem("rules = []\n", "zanity.toml:1: 'rules' is empty, so nothing would run; list at least one rule, or remove it to run the defaults.");
    try expectProblem("exclude = [\"a\" \"b\"]\n", "zanity.toml:1: items in 'exclude' must be separated by commas, such as [\"a\", \"b\"].");
    try expectProblem("rules = [\"recursion\"] extra\n", "zanity.toml:1: unexpected 'e' after a value; put each setting on its own line.");
}

test "a [paths] section turns rules off for the files its pattern matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var c = try parsed(arena_state.allocator(),
        \\disable = ["name-drift"]
        \\
        \\[paths."src/golden_test.zig"]
        \\disable = ["process-in-test", "filesystem-in-test"]
        \\
        \\[paths."tests/e2e/"]
        \\disable = ["network-in-test"]
        \\
        \\[paths."*_integration.py"]
        \\disable = ["database-in-test"]
        \\
    );
    c.dir = "/repo";
    try std.testing.expectEqual(@as(usize, 3), c.pathRules().len);
    try std.testing.expect(c.disabledAt("src/golden_test.zig", "process-in-test"));
    try std.testing.expect(!c.disabledAt("src/golden_test.zig", "network-in-test"));
    try std.testing.expect(!c.disabledAt("other/src/golden_test.zig", "process-in-test"));
    try std.testing.expect(c.disabledAt("tests/e2e/api/test_login.py", "network-in-test"));
    try std.testing.expect(!c.disabledAt("tests/unit/test_login.py", "network-in-test"));
    try std.testing.expect(c.disabledAt("deep/down/orders_integration.py", "database-in-test"));
    try std.testing.expect(!c.selection().enabled("name-drift"));
}
