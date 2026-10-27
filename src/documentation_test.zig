const std = @import("std");
const language = @import("language.zig");
const check = @import("check.zig");
const memory = @import("memory.zig");
const Facts = @import("facts.zig").Facts;

test "inference units retain attached documentation across languages" {
    const cases = [_]struct { path: []const u8, source: []const u8, expected: []const u8 }{
        .{ .path = "menu.swift", .source = "/// Loads languages.\n/// Data flow: menu.\n@MainActor\nfunc loadLanguages() -> [String] { [\"en-US\"] }", .expected = "/// Loads languages." },
        .{ .path = "menu.swift", .source = "/** Loads\n * languages. */\nfunc loadLanguages() {}", .expected = "/** Loads" },
        .{ .path = "menu.go", .source = "package main\n// Loads languages.\nfunc loadLanguages() {}", .expected = "// Loads languages." },
        .{ .path = "menu.rs", .source = "/// Loads languages.\n#[inline]\nfn load_languages() {}", .expected = "/// Loads languages." },
        .{ .path = "menu.java", .source = "class Menu {\n/** Loads languages. */\npublic void loadLanguages() {}\n}", .expected = "/** Loads languages." },
        .{ .path = "menu.cs", .source = "class Menu {\n/// Loads languages.\npublic void LoadLanguages() {}\n}", .expected = "/// Loads languages." },
        .{ .path = "menu.ts", .source = "/** Loads languages. */\nexport function loadLanguages() {}", .expected = "/** Loads languages." },
        .{ .path = "menu.py", .source = "def load_languages():\n    \"\"\"Loads languages.\"\"\"\n    pass\n", .expected = "def load_languages" },
        .{ .path = "menu.swift", .source = "// Detached header.\n\nfunc loadLanguages() {}", .expected = "func loadLanguages" },
        .{ .path = "menu.go", .source = "package main\nvar x = 1 // Other declaration.\nfunc loadLanguages() {}", .expected = "func loadLanguages" },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const limits: memory.Limits = .{ .captures = 1 << 14, .depth = 128, .per_file = 1024, .text_bytes = 1 << 16, .definitions = 128, .functions = 128, .calls = 128, .references = 1024 };
        const adapter = language.forPath(case.path).?;
        var enabled: @import("rules.zig").Set = .{};
        enabled.include("long-function");
        const checker = try check.Checker.initChecker(arena, try language.load(adapter), enabled);
        var text = try memory.Text.initText(arena, limits.text_bytes);
        var facts = try Facts.initFacts(arena, limits, &text);
        facts.path = case.path;
        facts.language = adapter.name;
        facts.collect_units = true;
        var scratch = try check.FileScratch.initCheckScratch(arena, limits);
        _ = try checker.check(.{ .scratch = &scratch, .text = &text, .facts = &facts }, case.source);
        const unit = for (facts.units.items()) |candidate| {
            if (candidate.kind == .function) break candidate;
        } else return error.MissingFunctionUnit;
        try std.testing.expectEqualStrings(case.expected, unit.source[0..@min(unit.source.len, case.expected.len)]);
        try std.testing.expect(std.mem.endsWith(u8, case.source, unit.source) or std.mem.indexOf(u8, case.source, unit.source) != null);
    }
}
