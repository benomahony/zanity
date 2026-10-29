//! Rule-selection changes reuse compiled query storage across watched checks.
const std = @import("std");
const language = @import("language.zig");
const ts = @import("ts.zig");
const rules = @import("rules.zig");
const Checker = @import("check.zig").Checker;

test "changing selected rules retains the compiled language query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loaded = try language.load(language.forPath("a.py").?);
    defer ts.ts_query_delete(loaded.query);
    var initial: rules.Set = .{};
    initial.include("assertion-message");
    var checker = try Checker.initChecker(arena.allocator(), loaded, initial);
    const original_query = checker.loaded.query;
    var replacement: rules.Set = .{};
    replacement.include("long-function");
    checker.selectRules(replacement);
    try std.testing.expect(checker.enabled.same(replacement));
    try std.testing.expectEqual(original_query, checker.loaded.query);
    try std.testing.expectEqual(original_query, checker.compiled.query);
}
