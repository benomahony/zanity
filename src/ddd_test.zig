const std = @import("std");
const assert = @import("assert.zig");
const config = @import("config.zig");
const ddd = @import("ddd.zig");

const glossary =
    \\# the project's words
    \\directional: [to, from]
    \\contexts:
    \\  - name: Shared
    \\    forbidden: [util, manager]
    \\    terms:
    \\      - name: Customer
    \\        definition: |
    \\          Someone who buys.
    \\          # not a comment
    \\        aliases:
    \\          - client
    \\          - 'user'
    \\  - name: Billing
    \\    kind: domain
    \\    domainVisionStatement: Get paid.
    \\    terms:
    \\    - name: Invoice
    \\      examples:
    \\        - Send the invoice.
    \\      aliases: [bill, "charge"]
    \\    - name: Purchase Order
    \\      aliases: [po]
    \\    paths:
    \\    - src/billing/**
    \\    forbidden: [discount]
    \\
;

fn parsed(arena: std.mem.Allocator, text: []const u8) !config.Config {
    if (text.len == 0) assert.panic("parsing an empty test glossary; pass the YAML under test", .{});
    var result: config.Config = .{};
    try ddd.parseGlossary(try arena.dupe(u8, text), &result);
    if (result.terms_len > config.max_terms) assert.panic("parsed {d} terms in room for {d}; parseGlossary() must refuse more", .{ result.terms_len, config.max_terms });
    return result;
}

test "a term's aliases become words to replace with its name, in lower case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), glossary);
    const terms = c.terms[0..c.terms_len];
    try std.testing.expectEqual(@as(usize, 7), terms.len);
    try std.testing.expectEqualStrings("user", terms[3].word);
    try std.testing.expectEqualStrings("customer", terms[3].canonical);
    try std.testing.expectEqualStrings("charge", terms[5].word);
    try std.testing.expectEqualStrings("invoice", terms[5].canonical);
}

test "a context with no paths holds the whole project's words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), glossary);
    try std.testing.expectEqualStrings("util", c.terms[0].word);
    try std.testing.expectEqualStrings("", c.terms[0].canonical);
    try std.testing.expectEqual(@as(u8, 0), c.terms[0].scope);
    try std.testing.expectEqual(@as(u8, 0), c.terms[3].scope);
    try std.testing.expectEqual(@as(usize, 2), c.directional_len);
}

test "a context with paths scopes its words, wherever its paths are listed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = try parsed(arena_state.allocator(), glossary);
    try std.testing.expectEqual(@as(usize, 1), c.scopes_len);
    try std.testing.expectEqualStrings("Billing", c.scopes[0].name);
    try std.testing.expect(!c.scopes[0].context);
    try std.testing.expectEqualStrings("src/billing/**", c.scopes[0].globs()[0]);
    try std.testing.expectEqual(@as(u8, 1), c.terms[5].scope);
    try std.testing.expectEqualStrings("discount", c.terms[6].word);
    try std.testing.expectEqual(@as(u8, 1), c.terms[6].scope);
}

test "mistakes in ddd.yaml name the line and what to write" {
    const Case = struct { yaml: []const u8, problem: []const u8 };
    const cases = [_]Case{
        .{ .yaml = "vocabulary:\n", .problem = "ddd.yaml:1: 'vocabulary' isn't a glossary key; the keys are contexts, directional and imports, and zanity's own settings go in zanity.yaml." },
        .{ .yaml = "directional: to\n", .problem = "ddd.yaml:1: 'directional' needs a list, such as directional: [a, b], or one '- item' per line below it." },
        .{ .yaml = "contexts:\n  - name: Billing\n    paths: [src/**]\n    colour: red\n", .problem = "ddd.yaml:4: 'colour' isn't a context key; a context takes name, kind, paths, forbidden and terms, and Contextive's domainVisionStatement and meta." },
        .{ .yaml = "contexts:\n  - paths: [src/**]\n", .problem = "ddd.yaml:2: a context with paths has no name; give it one, such as name: Billing." },
        .{ .yaml = "contexts:\n  - name: Billing\n    kind: team\n", .problem = "ddd.yaml:3: kind is 'team'; it must be context or domain." },
        .{ .yaml = "contexts:\n  - terms:\n      - aliases: [x]\n", .problem = "ddd.yaml:3: a term has no name; give it one, such as name: invoice." },
        .{ .yaml = "contexts:\n  - name: Billing\n    paths: [a/**]\n  - name: billing\n    paths: [b/**]\n", .problem = "ddd.yaml:4: the context 'billing' is listed twice; merge the two into one." },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try std.testing.expectError(error.InvalidConfig, parsed(arena_state.allocator(), case.yaml));
        try std.testing.expectEqualStrings(case.problem, config.problem[0..config.problem_len]);
    }
}
