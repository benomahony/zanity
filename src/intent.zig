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
        const said = try summary(scratch.text, item.doc);
        const fix = switch (odd) {
            0 => try scratch.text.format("Rename '{s}' to say what its docstring says it does: \"{s}\".", .{ item.name, said }),
            1 => try scratch.text.format("Rewrite the docstring \"{s}\" to say what '{s}' does, which its body does too.", .{ said, item.name }),
            else => try scratch.text.format("'{s}' is documented as \"{s}\"; make its body do that, or rename it and rewrite the docstring to say what the body does.", .{ item.name, said }),
        };
        try out.add(.{ .rule = "intent-mismatch", .path = item.path, .line = item.line, .column = item.column, .name = item.name, .score = score, .threshold = margin, .subject = item.subject, .message = message, .fix = fix });
    }
}

/// Bytes of a docstring a fix quotes: a long first sentence is cut at a word before this.
const max_summary = 200;

/// The docstring's first sentence, its wrapped lines joined and their comment markers dropped,
/// cut at a word to `max_summary` bytes when it runs longer.
fn summary(text: *memory.Text, doc: []const u8) error{LimitExceeded}![]const u8 {
    if (doc.len == 0) assert.panic("quoting an empty docstring; only documented functions are compared", .{});
    var joined: [max_summary]u8 = undefined;
    var len: usize = 0;
    var lines = std.mem.tokenizeAny(u8, doc, "\r\n");
    while (lines.next()) |line| {
        const bare = std.mem.trim(u8, line, " \t/#*!-");
        if (bare.len == 0) {
            if (len > 0) break;
            continue;
        }
        const room = joined.len - len - @intFromBool(len > 0);
        if (len > 0) joined[len] = ' ';
        len += @intFromBool(len > 0);
        const taken = bare[0..@min(bare.len, room)];
        @memcpy(joined[len..][0..taken.len], taken);
        len += taken.len;
        if (sentenceEnd(joined[0..len]) != null or taken.len < bare.len) break;
    }
    const said = if (sentenceEnd(joined[0..len])) |end| joined[0..end] else if (len == joined.len) joined[0 .. std.mem.lastIndexOfScalar(u8, &joined, ' ') orelse len] else joined[0..len];
    if (said.len == 0 or said.len > max_summary) assert.panic("quoted {d} bytes of a {d}-byte docstring", .{ said.len, doc.len });
    return text.copy(said);
}

/// Where the first sentence of `words` ends, just after its full stop, if it has one.
fn sentenceEnd(words: []const u8) ?usize {
    if (words.len > max_summary) assert.panic("looking for a sentence in {d} bytes, past the {d} a quote holds", .{ words.len, max_summary });
    var at: usize = 0;
    const end = while (std.mem.indexOfScalarPos(u8, words, at, '.')) |dot| : (at = dot + 1) {
        if (dot + 1 == words.len or words[dot + 1] == ' ') break dot + 1;
    } else return null;
    if (end > words.len or words[end - 1] != '.') assert.panic("a sentence of {d} bytes ends at {d}, not just after a full stop", .{ words.len, end });
    return end;
}

test "intent-mismatch names the one of name, docstring and body that disagrees" {
    var f: semantic.Fixture = .{};
    const described = [_]Described{ .{ .name = "send_invoice", .path = "a.py", .vectors = .{ &semantic.north, &semantic.east, &semantic.east_ish }, .doc = "# Charges the card on file.\n# Retries once." }, .{ .name = "charge", .path = "a.py", .vectors = .{ &semantic.east, &semantic.east_ish, &.{ 0.98, 0.2 } }, .doc = "Charges the card." } };
    try intentMismatch(f.scratch(), &described, 0.15, &f.insights);
    try std.testing.expectEqual(@as(usize, 1), f.fired());
    try std.testing.expect(std.mem.indexOf(u8, f.found[0].message, "its name disagrees with its docstring and body") != null);
    try std.testing.expectEqualStrings("Rename 'send_invoice' to say what its docstring says it does: \"Charges the card on file.\".", f.found[0].fix);
}

test "intent-mismatch quotes the docstring's first sentence across its wrapped lines" {
    var f: semantic.Fixture = .{};
    const room = f.scratch();
    try std.testing.expectEqualStrings("Read whatever the server sends until it has been quiet for `quiet` seconds, so a slow reply is not cut off.", try summary(room.text, "Read whatever the server sends until it has been quiet for `quiet` seconds, so a\n    slow reply is not cut off. Returns the bytes."));
    try std.testing.expectEqualStrings("The language named `name`, as facts.zig records it.", try summary(room.text, "/// The language named `name`, as facts.zig records it."));
    try std.testing.expectEqualStrings("Keeps the flag", try summary(room.text, "# Keeps the flag\n#\n# in the store."));
}
