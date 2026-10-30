//! Applies the edits of `check --fix` to a file's source, and moves the line numbers of the
//! findings left in it past the lines those edits added or removed.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Finding = @import("facts.zig").Finding;

/// Writes `source` into `out` with each edit that doesn't overlap an earlier one applied, marking
/// those findings fixed. An edit that ends past `source` is skipped, and edits stop once the next
/// would overflow `out`.
pub fn applyEdits(source: []const u8, findings: []Finding, out: []u8) error{LimitExceeded}!struct { bytes: []const u8, applied: usize } {
    var used: usize = 0;
    var cursor: usize = 0;
    var applied: usize = 0;
    for (findings) |*f| {
        const edit = f.edit orelse continue;
        if (edit.start > edit.end) assert.panic("the {s} edit at line {d} runs backwards, from byte {d} to {d}; an edit must start at or before its end", .{ f.rule, f.line + 1, edit.start, edit.end });
        if (edit.start < cursor or edit.end > source.len) continue;
        const kept = source[cursor..edit.start];
        if (used + kept.len + edit.replacement.len > out.len) break;
        @memcpy(out[used..][0..kept.len], kept);
        @memcpy(out[used + kept.len ..][0..edit.replacement.len], edit.replacement);
        used += kept.len + edit.replacement.len;
        cursor = edit.end;
        f.fixed = true;
        applied += 1;
    }
    const rest = source[cursor..];
    if (used + rest.len > out.len) {
        memory.exceeded = "bytes in one fixed file";
        return error.LimitExceeded;
    }
    @memcpy(out[used..][0..rest.len], rest);
    used += rest.len;
    if (cursor > source.len) assert.panic("applied edits up to byte {d} of a {d}-byte file; skip an edit that ends past the file", .{ cursor, source.len });
    if (applied > findings.len) assert.panic("applied {d} edits from {d} findings; each finding has at most one edit", .{ applied, findings.len });
    return .{ .bytes = out[0..used], .applied = applied };
}

/// Moves the findings that stay in a fixed file past the lines its edits added or removed.
pub fn shiftLines(source: []const u8, findings: []Finding) void {
    if (!(findings.len > 0)) assert.panic("expected findings to shift, got none for {d} bytes; call shiftLines() only for a file with findings", .{source.len});
    var delta: i64 = 0;
    for (findings) |*f| {
        if (f.fixed) {
            const edit = f.edit orelse unreachable;
            const removed = std.mem.count(u8, source[edit.start..edit.end], "\n");
            delta += @as(i64, @intCast(std.mem.count(u8, edit.replacement, "\n"))) - @as(i64, @intCast(removed));
            continue;
        }
        f.line = @intCast(@as(i64, f.line) + delta);
    }
    if (delta < -@as(i64, @intCast(source.len))) assert.panic("expected edits to remove at most the file's {d} bytes of lines, got {d} lines; shiftLines() must count newlines only inside each edit's span", .{ source.len, delta });
}
