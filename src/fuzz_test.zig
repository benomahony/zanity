const std = @import("std");
const assert = @import("assert.zig");
const adapters = @import("adapters");
const language = @import("language.zig");
const check = @import("check.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const Facts = @import("facts.zig").Facts;

const limits: memory.Limits = .{ .captures = 1 << 14, .depth = 1 << 10, .per_file = 1 << 12, .file_bytes = 4096, .text_bytes = 1 << 16, .definitions = 1 << 10, .functions = 1 << 10, .calls = 1 << 12 };

fn everyRule() rules.Set {
    var set: rules.Set = .{};
    for (rules.all) |r| set.include(r.name);
    if (set.len != rules.all.len) assert.panic("the fuzz rule set enabled {d} of {d} rules; a rule is missing from include()", .{ set.len, rules.all.len });
    if (!set.enabled(rules.all[set.len - 1].name)) assert.panic("the fuzz rule set does not enable '{s}', the last rule; build the fuzz rule set from every rule in rules.all", .{rules.all[set.len - 1].name});
    return set;
}

/// One checker per language for the whole fuzz run: compiling a language's queries for every
/// input took most of each run.
var checkers: [language.count]?check.Checker = @splat(null);

fn checkerFor(adapter: *const language.Adapter) !*const check.Checker {
    const slot = &checkers[language.indexOf(adapter)];
    if (slot.* == null) slot.* = try check.Checker.initChecker(std.heap.page_allocator, try language.load(adapter), everyRule());
    const checker = &slot.*.?;
    const built = checker.loaded.adapter;
    if (built != adapter) assert.panic("the fuzz checker for {s} was built for {s}; checkerFor() keeps one slot per adapter", .{ adapter.name, built.name });
    if (checker.enabled.len == 0) assert.panic("the fuzz checker for {s} runs no rules; build it from everyRule()", .{adapter.name});
    return checker;
}

fn checkAnything(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const adapter = &adapters.all[smith.value(u8) % adapters.all.len];
    var buffer: [4096]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    const checker = try checkerFor(adapter);
    var text = try memory.Text.initText(arena, limits.text_bytes);
    var facts = try Facts.initFacts(arena, limits, &text);
    facts.path = "fuzz";
    facts.language = adapter.name;
    var scratch = try check.FileScratch.initCheckScratch(arena, limits);
    const result = checker.check(.{ .scratch = &scratch, .text = &text, .facts = &facts }, source) catch |e| switch (e) {
        error.LimitExceeded => return,
        else => return e,
    };
    if (!std.sort.isSorted(check.Diagnostic, result.diagnostics, {}, check.Diagnostic.reportOrder)) assert.panic("expected diagnostics in report order, got {d} diagnostics out of order; File.finish() must sort diagnostics with Diagnostic.reportOrder", .{result.diagnostics.len});
    for (result.diagnostics) |d| if (rules.find(d.rule) == null or d.message.len == 0) assert.panic("fuzzing reported rule '{s}' with message '{s}'; every finding needs a known rule and a message, so find the report() call for it and give it a rule from rules.all and a message", .{ d.rule, d.message });
}

test "checking any bytes in any language never breaks an invariant" {
    try std.testing.fuzz({}, checkAnything, .{ .corpus = &.{
        "\x00def f(x):\n    assert x, 'm'\n    while True:\n        f(x)\n",
        "\x01fn f(a: u32) void {\n    std.debug.assert(a > 0);\n    while (true) {}\n}\nconst S = struct {};\n",
        "\x00@decorator\nclass C:\n    def m(self):\n        x = 5\n        assert x is not None\n",
        "\x01const x = if (a) |b| b else c;\n",
    } });
}
