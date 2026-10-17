const std = @import("std");
const assert = @import("assert.zig");
const config = @import("config.zig");
const rules = @import("rules.zig");

fn parsed(arena: std.mem.Allocator, text: []const u8) !config.Config {
    if (text.len == 0) assert.panic("parsing an empty test config; pass the YAML under test", .{});
    const result = try config.parseConfig(try arena.dupe(u8, text));
    if (result.exclude_len > config.max_excludes) assert.panic("parsed {d} exclude patterns in room for {d}; parseConfig() must refuse lists longer than max_excludes", .{ result.exclude_len, config.max_excludes });
    return result;
}

fn expectProblem(text: []const u8, expected: []const u8) !void {
    if (!std.mem.startsWith(u8, expected, config.file_name)) assert.panic("expected problem '{s}' should start with the file name; start the expected problem with zanity.yaml:<line>:", .{expected});
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidConfig, parsed(arena_state.allocator(), text));
    try std.testing.expectEqualStrings(expected, config.problem[0..config.problem_len]);
    if (config.problem_len == 0) assert.panic("the problem for '{s}' is empty; fail() must record a description of the problem", .{text});
}

test "a zanity.yaml chooses rules, excludes paths and sets how --infer asks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(),
        \\# which files are skipped
        \\exclude:
        \\  - vendor/   # third-party
        \\  - "tests/golden/**"
        \\infer:
        \\  concurrency: 16
        \\  threshold: 0.95
        \\  url: http://127.0.0.1:8009/
        \\  model: 'kev-latest'
        \\  api_key_env: "KEV_API_KEY"
        \\rules:
        \\  select: [recursion, long-function, NASA02]
        \\
    );
    try std.testing.expect(c.rules.?.enabled("recursion"));
    try std.testing.expect(c.rules.?.enabled("unbounded-loop"));
    try std.testing.expect(!c.rules.?.enabled("duplicate-name"));
    try std.testing.expectEqual(@as(usize, 2), c.exclude_len);
    try std.testing.expectEqualStrings("tests/golden/**", c.exclude[1]);
    try std.testing.expectEqual(@as(?u32, 16), c.concurrency);
    try std.testing.expectEqual(@as(?f64, 0.95), c.threshold);
    try std.testing.expectEqualStrings("http://127.0.0.1:8009/", c.url.?);
    try std.testing.expectEqualStrings("kev-latest", c.model.?);
    try std.testing.expectEqualStrings("KEV_API_KEY", c.api_key_env.?);
}

test "rules selects and disables rules, as zanity init writes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(),
        \\exclude: [vendor/]
        \\infer:
        \\  concurrency: 4
        \\rules:
        \\  select: [all]
        \\  disable:
        \\    - long-file
        \\    # - recursion
        \\
    );
    const chosen = c.selection(false);
    try std.testing.expect(chosen.enabled("restated-type"));
    try std.testing.expect(chosen.enabled("recursion"));
    try std.testing.expect(!chosen.enabled("long-file"));
    try std.testing.expectEqual(@as(?u32, 4), c.concurrency);
}

test "'all' enables every rule, including those off by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "rules:\n  select: [all]\n  disable: [long-file]\n");
    const chosen = c.selection(false);
    try std.testing.expect(chosen.enabled("restated-type"));
    try std.testing.expect(chosen.enabled("wide-scope"));
    try std.testing.expect(!chosen.enabled("long-file"));
    try std.testing.expectEqual(rules.all.len - 1, chosen.len);
}

test "disable removes rules from the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "rules:\n  disable: [duplicate-name, name-drift]\n");
    const chosen = c.selection(false);
    try std.testing.expect(!chosen.enabled("duplicate-name"));
    try std.testing.expect(!chosen.enabled("name-drift"));
    try std.testing.expect(chosen.enabled("long-function"));
}

test "strict adds the strict rules to the defaults, without what disable removes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "rules:\n  disable: [recursion]\n");
    try std.testing.expect(!c.selection(false).enabled("assertion-density"));
    const chosen = c.selection(true);
    try std.testing.expect(chosen.enabled("assertion-density"));
    try std.testing.expect(chosen.enabled("long-function"));
    try std.testing.expect(!chosen.enabled("recursion"));
    try std.testing.expect(!chosen.enabled("misleading-error"));
}

test "select 'strict' runs the defaults and the strict rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "rules:\n  select: [strict]\n");
    const chosen = c.selection(false);
    try std.testing.expect(chosen.enabled("unbounded-loop"));
    try std.testing.expect(chosen.enabled("long-function"));
    try std.testing.expect(!chosen.enabled("misleading-error"));
}

test "a file of only comments runs the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "# nothing yet\n");
    try std.testing.expectEqual(null, c.rules);
    try std.testing.expectEqual(@as(usize, 0), c.exclude_len);
}

test "the glossary may sit in zanity.yaml" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), "contexts:\n  - name: Shared\n    forbidden: [util]\n");
    try std.testing.expectEqual(@as(usize, 1), c.terms_len);
    try std.testing.expectEqualStrings("util", c.terms[0].word);
    try std.testing.expectEqualStrings("zanity.yaml", c.glossary_file);
}

test "mistakes in zanity.yaml name the line and what to write" {
    try expectProblem("rules:\n  select: [recursions]\n", "zanity.yaml:2: 'recursions' isn't a rule; the rules are listed in the README, 'all' names every rule, 'strict' the defaults and the strict rules, and 'zanity check --rules' takes the same names.");
    try expectProblem("\ndisabled: []\n", "zanity.yaml:2: 'disabled' isn't a setting; the settings are exclude, rules, infer and paths, and the glossary's contexts and directional.");
    try expectProblem("[rules]\n", "zanity.yaml:1: expected a key such as 'name:'; write each setting as name: value.");
    try expectProblem("rules: [all]\n", "zanity.yaml:1: 'rules' takes its settings on the indented lines below it, one name: value per line.");
    try expectProblem("rules:\n  rules: [all]\n", "zanity.yaml:2: 'rules' isn't a rules setting; the settings are select and disable.");
    try expectProblem("rules:\n  select: []\n", "zanity.yaml:2: 'select' is empty, so nothing would run; list at least one rule, or remove it to run the defaults.");
    try expectProblem("rules:\n  select: [recursion] extra\n", "zanity.yaml:2: unexpected 'e' after a value; put each setting on its own line.");
    try expectProblem("paths:\n  - disable: [recursion]\n", "zanity.yaml:2: a paths entry names no files; give it a pattern, such as files: tests/e2e/.");
    try expectProblem("paths:\n  - files: tests/\n    rules: [recursion]\n", "zanity.yaml:3: 'rules' isn't a paths setting; the settings are files and disable.");
    try expectProblem("infer:\n  concurrency: 500\n", "zanity.yaml:2: concurrency is 500; it must be between 1 and 64.");
    try expectProblem("infer:\n  threshold: 1.5\n", "zanity.yaml:2: threshold is 1.5; it must be above 0 and at most 1, such as 0.9 to report only what the model is at least 90% sure of.");
    try expectProblem("infer:\n  threshold: high\n", "zanity.yaml:2: 'threshold' needs a number, such as threshold: 0.9.");
    try expectProblem("infer:\n  models: x\n", "zanity.yaml:2: 'models' isn't an infer setting; the settings are url, model, api_key_env, concurrency and threshold.");
    try expectProblem("infer:\n  url: localhost:8009\n", "zanity.yaml:2: url is 'localhost:8009'; it must start with http:// or https://, such as http://127.0.0.1:8009.");
    try expectProblem("infer:\n  model: \"\"\n", "zanity.yaml:2: 'model' is empty; name one, or remove the line to use the default.");
    try expectProblem("exclude: [\"a\" \"b\"]\n", "zanity.yaml:1: items in 'exclude' must be separated by commas, such as [a, b].");
    try expectProblem("exclude: [*.py]\n", "zanity.yaml:1: a value of 'exclude' starts with '*', which YAML reads as more than text; put the value in quotes.");
}

test "a paths entry turns rules off for the files its pattern matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var c = try parsed(arena_state.allocator(),
        \\rules:
        \\  disable: [name-drift]
        \\paths:
        \\  - files: src/golden_test.zig
        \\    disable: [process-in-test, filesystem-in-test]
        \\  - files: tests/e2e/
        \\    disable: [network-in-test]
        \\  - files: "*_integration.py"
        \\    disable: [database-in-test]
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
    try std.testing.expect(!c.selection(false).enabled("name-drift"));
}
