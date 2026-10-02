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
