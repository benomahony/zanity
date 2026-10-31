//! Writing `--fix`'s result: one file's edits, swapped into place without losing a concurrent write.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const zclig = @import("zclig");
const edits = @import("edits.zig");
const exchange = @import("exchange.zig");
const Finding = @import("facts.zig").Finding;

/// Applies the non-overlapping edits of one file's findings, which are in source order.
/// An edit that overlaps an earlier one waits for the next run.
pub fn fixFile(ctx: *zclig.Context, ws: anytype, findings: []Finding) !usize {
    const path = findings[0].path;
    if (!std.mem.eql(u8, path, findings[findings.len - 1].path)) assert.panic("expected the findings of one file, got {s} and {s}; fixFiles() must pass one file's findings at a time", .{ path, findings[findings.len - 1].path });
    var any = false;
    for (findings) |f| any = any or f.edit != null;
    if (!any) return 0;
    const source = Io.Dir.cwd().readFile(ws.io, path, ws.source) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not read {s} to fix it: {t}.", .{ path, e }), "Check the file is still there and readable.");
    };
    const spliced = try edits.applyEdits(source, findings, ws.fixed);
    try replaceFile(ctx, ws, .{ .path = path, .read = source, .fixed = spliced.bytes });
    edits.shiftLines(source, findings);
    const applied = spliced.applied;
    if (applied == 0) assert.panic("expected at least one edit to apply to {s}, got none; fixFiles() must call fixFile() only for a file with an edit", .{path});
    return applied;
}

/// A file to fix: its path, the bytes the fixes were made against, and the fixed bytes.
const Replacement = struct { path: []const u8, read: []const u8, fixed: []const u8 };

/// Swaps the fixed file into place in one step, then compares what it displaced with what the
/// fixes were made against. When another program wrote the file in the meantime, the swap is
/// undone so its write stays, and whatever cannot be put back is kept beside the file, never deleted.
fn replaceFile(ctx: *zclig.Context, ws: anytype, r: Replacement) !void {
    const path = r.path;
    const bytes = r.fixed;
    if (!(path.len > 0 and bytes.len <= ws.fixed.len)) assert.panic("expected a path and at most {d} bytes, got '{s}' and {d} bytes; fixFile() must write at most the fixed buffer's size", .{ ws.fixed.len, path, bytes.len });
    const cwd = Io.Dir.cwd();
    const permissions = (cwd.statFile(ws.io, path, .{}) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not stat {s} to fix it: {t}.", .{ path, e }), "Check the file is still there and readable.");
    }).permissions;
    var atomic = cwd.createFileAtomic(ws.io, path, .{ .permissions = permissions, .replace = true }) catch |e| {
        return ctx.fail(.io, try ws.text.format("Could not write the fixed {s}: {t}.", .{ path, e }), "Check the directory is writable.");
    };
    defer atomic.deinit(ws.io);
    try atomic.file.writeStreamingAll(ws.io, bytes);
    atomic.file.close(ws.io);
    atomic.file_open = false;
    const hex = std.fmt.hex(atomic.file_basename_hex);
    const temporary = if (std.fs.path.dirname(path)) |dir| try ws.text.format("{s}{c}{s}", .{ dir, std.fs.path.sep, &hex }) else try ws.text.copy(&hex);
    if (!std.mem.endsWith(u8, temporary, &hex) or std.mem.eql(u8, temporary, path)) assert.panic("the temporary file for {s} is '{s}', which is not the atomic file '{s}' beside it; build it from the file's directory and the atomic file's name", .{ path, temporary, &hex });
    exchange.exchange(temporary, path) catch |e| switch (e) {
        error.OriginalKeptAsBackup => return ctx.fail(.io, try ws.text.format("Swapping the fixed {s} into place failed halfway; the fixed file is in place and the original is kept at {s}{s}.", .{ path, temporary, exchange.backup_suffix }), "Compare the two files, keep the one you want, then run zanity check --fix again."),
        else => return ctx.fail(.io, try ws.text.format("Could not swap the fixed {s} into place: {t}.", .{ path, e }), "Check the file system supports atomic renames, then run zanity check --fix again."),
    };
    if (try unchanged(ws.io, temporary, r.read)) return;
    exchange.exchange(temporary, path) catch |e| {
        atomic.file_exists = false;
        return ctx.fail(.io, try ws.text.format("{s} changed while zanity was fixing it, and putting the other version back failed ({t}); it is kept at {s}.", .{ path, e, temporary }), "Compare the two files, keep the one you want, then run zanity check --fix again.");
    };
    if (!try unchanged(ws.io, temporary, bytes)) {
        atomic.file_exists = false;
        return ctx.fail(.io, try ws.text.format("{s} changed twice while zanity was fixing it; the latest version is in place and the one before it is kept at {s}.", .{ path, temporary }), "Compare the two files, keep the one you want, then run zanity check --fix again.");
    }
    return ctx.fail(.io, try ws.text.format("{s} changed while zanity was fixing it, so it was left as it is.", .{path}), "Run zanity check --fix again once nothing else is editing it.");
}

/// Whether the file at `path` still holds exactly `expected`.
fn unchanged(io: Io, path: []const u8, expected: []const u8) !bool {
    if (path.len == 0) assert.panic("asked whether a file with no path is unchanged; pass the path fixFile() read", .{});
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var chunk: [16 * 1024]u8 = undefined;
    var offset: usize = 0;
    for (0..expected.len / chunk.len + 2) |_| {
        const n = try file.readPositionalAll(io, &chunk, offset);
        if (n > expected.len - offset or !std.mem.eql(u8, chunk[0..n], expected[offset..][0..n])) return false;
        offset += n;
        if (offset > expected.len) assert.panic("compared {d} bytes of {s} against {d}; stop as soon as the file is longer than expected", .{ offset, path, expected.len });
        if (n < chunk.len) return offset == expected.len;
    }
    assert.panic("read {d} bytes of {s} in chunks without reaching its end; the loop must allow one chunk past {d} bytes", .{ offset, path, expected.len });
}

test "a fix is written only over the bytes it was made against" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, "a.py" });
    const line = "x = 1\n";
    const long = try arena.alloc(u8, line.len * 5000);
    for (0..5000) |i| @memcpy(long[i * line.len ..][0..line.len], line);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = long });
    try std.testing.expect(try unchanged(io, path, long));
    try std.testing.expect(!try unchanged(io, path, long[1..]));
    try std.testing.expect(!try unchanged(io, path, try std.mem.concat(arena, u8, &.{ long, "y = 2\n" })));
    try std.testing.expect(!try unchanged(io, path, try std.mem.concat(arena, u8, &.{ "x = 2\n", long[line.len..] })));
}
