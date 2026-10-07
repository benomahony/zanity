//! Small comparisons of text that several checks share.
const std = @import("std");
const assert = @import("assert.zig");

/// Whether `needle` is one of the names in `haystack`, such as a call in a language's name table.
pub fn contains(haystack: []const []const u8, needle: []const u8) bool {
    if (needle.len == 0) assert.panic("looked up an empty name in a table of {d} names; skip empty names before calling contains()", .{haystack.len});
    for (haystack) |h| {
        if (h.len == 0) assert.panic("a name table holds an empty entry while looking up '{s}'; remove it from the table", .{needle});
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Byte order, for sorting names, paths and lines, none of which may be empty.
pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) assert.panic("sorting an empty text against '{s}'; drop empty texts before sorting", .{b});
    if (b.len == 0) assert.panic("sorting '{s}' against an empty text; drop empty texts before sorting", .{a});
    return std.mem.order(u8, a, b) == .lt;
}

/// Whether two texts are equal once whitespace is ignored, as `a . b` and `a.b` are.
pub fn sameText(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    for (0..a.len + b.len + 1) |_| {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
        if (i > a.len) assert.panic("comparing '{s}' with '{s}' ran past the first at byte {d}; the loop in sameText() must stop at the end of both strings", .{ a, b, i });
        if (j > b.len) assert.panic("comparing '{s}' with '{s}' ran past the second at byte {d}; the loop in sameText() must stop at the end of both strings", .{ a, b, j });
    }
    unreachable;
}

/// The first line of a node's text, without a trailing `{` or `:`: what a message quotes.
/// Whether what starts at `start`, or the line before it, is a decorator, annotation or attribute, such as `@app.route`,
/// `@Override` or `#[test]`, which registers or changes what follows, so something else fixes its
/// shape.
pub fn decoratedAt(source: []const u8, start: usize) bool {
    if (start > source.len) assert.panic("looking above byte {d} of a {d}-byte file; pass a function from this file", .{ start, source.len });
    const own = std.mem.trimStart(u8, source[start..], " \t");
    if (std.mem.startsWith(u8, own, "@") or std.mem.startsWith(u8, own, "#[")) return true;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |n| n else return false;
    const above_start = if (std.mem.lastIndexOfScalar(u8, source[0..line_start], '\n')) |n| n + 1 else 0;
    if (above_start > line_start) assert.panic("the line above byte {d} starts at {d}, after it ends at {d}", .{ start, above_start, line_start });
    const above = std.mem.trim(u8, source[above_start..line_start], " \t\r");
    return std.mem.startsWith(u8, above, "@") or std.mem.startsWith(u8, above, "#[");
}

/// Whether `name` is a dunder name such as `__init__`, which the language calls rather than the author.
pub fn dunder(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is a dunder name; skip empty names first", .{});
    const result = name.len > 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
    if (result and name.len <= 4) assert.panic("'{s}' was taken for a dunder name, but those need at least 5 bytes, like __x__", .{name});
    return result;
}

pub fn header(text: []const u8) []const u8 {
    if (text.len == 0) assert.panic("asked for the first line of an empty node; the capture matched no text", .{});
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var line = std.mem.trim(u8, text[0..line_end], " \t\r");
    if (std.mem.indexOf(u8, line, " {")) |brace| {
        const before = line[0..brace];
        if (before.len > 0 and (before[before.len - 1] == ')' or std.ascii.isAlphanumeric(before[before.len - 1]))) line = before;
    }
    const result = std.mem.trimEnd(u8, line, " \t:{}");
    if (result.len > line_end) assert.panic("the first line of '{s}' came out longer than the line itself ({d} > {d}); header() must only trim the line, so check its slicing", .{ text[0..line_end], result.len, line_end });
    return result;
}
