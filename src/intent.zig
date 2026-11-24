//! intent-mismatch: a function whose name, docstring and body tell different stories, judged by
//! which of the three is furthest from the other two.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const store = @import("store.zig");
const vectors = @import("vectors.zig");
const semantic = @import("semantic.zig");
const Insight = semantic.Insight;

pub const Described = struct {
    name: []const u8,
    path: []const u8,
    line: u32 = 0,
    column: u32 = 0,
    vectors: [3][]const f32,
    /// The docstring or comment above the function, as written, which a fix quotes.
    doc: []const u8,
    subject: store.Digest = @splat('0'),
};

const parts = [3][]const u8{ "name", "docstring", "body" };

pub fn intentMismatch(scratch: semantic.Room, items: []const Described, margin: f64, out: *memory.Bounded(Insight)) !void {
    if (!(margin > 0 and margin <= 1)) assert.panic("intent-mismatch at a margin of {d}", .{margin});
    if (items.len > 0 and items[0].vectors[0].len == 0) assert.panic("'{s}' has a name vector with no values", .{items[0].name});
    for (items) |item| {
        var odd: usize = 0;
        var score: f64 = -2;
        for (0..3) |x| {
            const a = item.vectors[(x + 1) % 3];
            const b = item.vectors[(x + 2) % 3];
            const s: f64 = vectors.cosine(a, b) - @max(vectors.cosine(item.vectors[x], a), vectors.cosine(item.vectors[x], b));
            if (s <= score) continue;
            score = s;
            odd = x;
        }
        const message = try scratch.text.format("'{s}': its {s} disagrees with its {s} and {s}, which agree with each other ({d:.2} apart).", .{ item.name, parts[odd], parts[(odd + 1) % 3], parts[(odd + 2) % 3], score });
        const said = summary(item.doc);
        const fix = switch (odd) {
            0 => try scratch.text.format("Rename '{s}' to say what its docstring says it does: \"{s}\".", .{ item.name, said }),
            1 => try scratch.text.format("Rewrite the docstring \"{s}\" to say what '{s}' does, which its body does too.", .{ said, item.name }),
            else => try scratch.text.format("'{s}' is documented as \"{s}\"; make its body do that, or rename it and rewrite the docstring to say what the body does.", .{ item.name, said }),
        };
        try out.add(.{ .rule = "intent-mismatch", .path = item.path, .line = item.line, .column = item.column, .name = item.name, .score = score, .threshold = margin, .subject = item.subject, .message = message, .fix = fix });
    }
}

/// Bytes of a docstring a fix quotes.
const max_summary = 100;

/// The docstring's first line without its comment markers, cut at a word to `max_summary` bytes.
fn summary(doc: []const u8) []const u8 {
    if (doc.len == 0) assert.panic("quoting an empty docstring; only documented functions are compared", .{});
    var lines = std.mem.tokenizeAny(u8, doc, "\r\n");
    const first = while (lines.next()) |line| {
        const bare = std.mem.trim(u8, line, " \t/#*!-");
        if (bare.len > 0) break bare;
    } else doc;
    if (first.len <= max_summary) return first;
    const cut = std.mem.lastIndexOfScalar(u8, first[0..max_summary], ' ') orelse max_summary;
    const said = first[0..cut];
    if (said.len == 0 or said.len > max_summary) assert.panic("cut a {d}-byte docstring line to {d} bytes", .{ first.len, said.len });
    return said;
}

test "intent-mismatch names the one of name, docstring and body that disagrees" {
    var f: semantic.Fixture = .{};
    const described = [_]Described{ .{ .name = "send_invoice", .path = "a.py", .vectors = .{ &semantic.north, &semantic.east, &semantic.east_ish }, .doc = "# Charges the card on file.\n# Retries once." }, .{ .name = "charge", .path = "a.py", .vectors = .{ &semantic.east, &semantic.east_ish, &.{ 0.98, 0.2 } }, .doc = "Charges the card." } };
    try intentMismatch(f.scratch(), &described, 0.15, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.fired());
    try std.testing.expect(std.mem.indexOf(u8, f.found[0].message, "its name disagrees with its docstring and body") != null);
    try std.testing.expectEqualStrings("Rename 'send_invoice' to say what its docstring says it does: \"Charges the card on file.\".", f.found[0].fix);
}
