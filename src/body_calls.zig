//! Whether one function's source calls another by name, read from the text alone, for the
//! --semantic rules that leave a function and what it calls alone.
const std = @import("std");
const assert = @import("assert.zig");

const definition_keywords = [_][]const u8{ "fn", "def", "func", "function" };

pub fn calls(source: []const u8, name: []const u8) bool {
    if (name.len == 0) assert.panic("looking for a call to a function with no name; facts.unit() records every name", .{});
    var from: usize = 0;
    for (0..source.len) |_| {
        const at = std.mem.indexOfPos(u8, source, from, name) orelse return false;
        const end = at + name.len;
        const starts = at == 0 or !(std.ascii.isAlphanumeric(source[at - 1]) or source[at - 1] == '_');
        if (starts and end < source.len and source[end] == '(' and !defines(source[0..at])) return true;
        from = end;
    }
    if (from > source.len) assert.panic("searched past the end of a {d}-byte body for '{s}'", .{ source.len, name });
    return false;
}

/// Whether the code before a name ends in a keyword that defines it, past any qualifiers such as
/// Lua's `function M.setup` or `function M:setup`, so the name there is defined and not called.
fn defines(prefix: []const u8) bool {
    var rest = std.mem.trimEnd(u8, prefix, " \t");
    for (0..prefix.len + 1) |_| {
        if (rest.len == 0) break;
        const last = rest.len - 1;
        if (rest[last] != '.' and rest[last] != ':') break;
        const qualifier = std.mem.trimEnd(u8, rest[0..last], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_");
        if (qualifier.len == last) break;
        rest = std.mem.trimEnd(u8, qualifier, " \t");
    }
    if (rest.len > prefix.len) assert.panic("trimming '{s}' grew it to '{s}'", .{ prefix, rest });
    for (definition_keywords) |keyword| {
        if (!std.mem.endsWith(u8, rest, keyword)) continue;
        const at = rest.len - keyword.len;
        if (at == 0 or !(std.ascii.isAlphanumeric(rest[at - 1]) or rest[at - 1] == '_')) return true;
    }
    if (rest.len > 0 and (rest[rest.len - 1] == ' ' or rest[rest.len - 1] == '\t')) assert.panic("'{s}' still ends in a space after trimming '{s}'", .{ rest, prefix });
    return false;
}

test "a body calls a name only where it is called, not where a longer name or a definition contains it" {
    try std.testing.expect(calls("x = cache.replay(y)", "replay"));
    try std.testing.expect(!calls("x = replayAll(y)", "replay"));
    try std.testing.expect(!calls("x = myreplay(y)", "replay"));
    try std.testing.expect(!calls("pub fn replay(y: u8) void {}", "replay"));
    try std.testing.expect(!calls("def replay(y):", "replay"));
}

test "a name defined with any language's keyword, or under a Lua table, is not a call" {
    try std.testing.expect(!calls("func replay(y int) {}", "replay"));
    try std.testing.expect(!calls("export async function replay(y) {}", "replay"));
    try std.testing.expect(!calls("function M.replay(y)", "replay"));
    try std.testing.expect(!calls("function M.sub:replay(y)", "replay"));
    try std.testing.expect(calls("return M.replay(y)", "replay"));
    try std.testing.expect(calls("local x = undef(y) or replay(y)", "replay"));
}
