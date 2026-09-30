//! Suppression comments such as `# zanity: ignore[long-function]`, which silence a rule on one line.
const std = @import("std");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const memory = @import("memory.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;
const sameText = check.sameText;
const weak = @import("weak.zig");

pub fn collectSuppressions(self: *File) !void {
    if (self.s.suppressions.len != 0) std.debug.panic("{s}: {d} suppression comments left from the previous file; clearFile must run first", .{ self.work.facts.path, self.s.suppressions.len });
    const comment = self.v.comment orelse return;
    for (self.index.triples) |t| {
        if (t.id != comment) continue;
        const start = self.s.codes.len;
        if (!try parseIgnore(&self.s.codes, t.node.text(self.source))) continue;
        try self.s.suppressions.add(.{ .line = ts.ts_node_start_point(t.node).row, .start = start, .len = self.s.codes.len - start });
    }
    if (self.s.suppressions.len > self.index.triples.len) std.debug.panic("{s}: {d} suppressions from {d} captured nodes; each needs its own comment", .{ self.work.facts.path, self.s.suppressions.len, self.index.triples.len });
}

pub fn suppressed(self: *File, line: u32, rule: []const u8) bool {
    const found = rules.find(rule) orelse unreachable;
    if (!found.answers(rule)) std.debug.panic("rules.find('{s}') returned rule {s}, which does not answer to that name", .{ rule, found.name });
    if (line > std.mem.count(u8, self.source, "\n")) std.debug.panic("{s}: checking suppressions on line {d} of a {d}-line file", .{ self.work.facts.path, line + 1, std.mem.count(u8, self.source, "\n") + 1 });
    for (self.s.suppressions.items()) |s| {
        if (s.line != line) continue;
        if (s.len == 0) return true;
        for (self.s.codes.items()[s.start..][0..s.len]) |code| if (found.answers(code)) return true;
    }
    return false;
}

pub fn parseIgnore(codes: *memory.Bounded([]const u8), comment: []const u8) !bool {
    if (comment.len == 0) std.debug.panic("parsing a suppression from an empty comment; the comment capture matched no text", .{});
    for (0..comment.len) |i| {
        const j = ignoreMarkerEnd(comment, i) orelse continue;
        if (j >= comment.len or comment[j] != '[') return true;
        const close = std.mem.indexOfScalarPos(u8, comment, j, ']') orelse return true;
        if (close <= j) std.debug.panic("the suppression list in '{s}' closes at byte {d}, before it opens at {d}", .{ comment, close, j });
        var it = std.mem.splitScalar(u8, comment[j + 1 .. close], ',');
        while (it.next()) |raw| {
            const code = std.mem.trim(u8, raw, " \t");
            if (code.len > 0) try codes.add(code);
        }
        return true;
    }
    return false;
}

/// The word that starts a suppression comment, before `ignore`.
const marker = "zanity:";

/// Where the text after `zanity: ignore` starting at `i` begins, or null if there is no marker there.
fn ignoreMarkerEnd(comment: []const u8, i: usize) ?usize {
    if (i >= comment.len) std.debug.panic("looked for a suppression at byte {d} of the {d}-byte comment '{s}'; parseIgnore() must call ignoreMarkerEnd() with a byte inside the comment", .{ i, comment.len, comment });
    if (!std.ascii.startsWithIgnoreCase(comment[i..], marker)) return null;
    const before = std.mem.trimEnd(u8, comment[0..i], " \t");
    if (before.len > 0 and std.ascii.isAlphanumeric(before[before.len - 1])) return null;
    var j = i + marker.len;
    while (j < comment.len and std.ascii.isWhitespace(comment[j])) j += 1;
    if (!std.ascii.startsWithIgnoreCase(comment[j..], "ignore")) return null;
    j += 6;
    if (j < comment.len and (std.ascii.isAlphanumeric(comment[j]) or comment[j] == '_')) return null;
    while (j < comment.len and std.ascii.isWhitespace(comment[j])) j += 1;
    if (j > comment.len) std.debug.panic("the suppression marker in '{s}' ends at byte {d}, past the comment; ignoreMarkerEnd() must stop at the end of the comment", .{ comment, j });
    return j;
}
