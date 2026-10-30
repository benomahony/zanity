//! Swapping what two paths name in one step, so a file can be replaced while what it held is kept
//! for comparison: `renameat2(RENAME_EXCHANGE)` on Linux, `renameatx_np(RENAME_SWAP)` on macOS,
//! and `ReplaceFileW` with a backup on Windows.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");

pub const Error = error{ ExchangeFailed, NameTooLong, Unsupported, OriginalKeptAsBackup };

/// What Windows appends to the replaced file's name while it is kept as a backup. When a swap
/// fails with `error.OriginalKeptAsBackup`, the original file is at the first path plus this.
pub const backup_suffix = ".zanity-old";

/// Swaps the files at `a` and `b`, relative to the working directory: afterwards `a` holds what
/// `b` held and `b` what `a` held. Nothing can write to `b` between its old and new contents.
pub fn exchange(a: []const u8, b: []const u8) Error!void {
    if (a.len == 0 or b.len == 0) assert.panic("swapping '{s}' with '{s}'; exchange() needs two paths", .{ a, b });
    if (std.mem.eql(u8, a, b)) assert.panic("swapping '{s}' with itself; pass the temporary file and the file it replaces", .{a});
    switch (builtin.os.tag) {
        .linux, .macos => try exchangePosix(a, b),
        .windows => try exchangeWindows(a, b),
        else => return error.Unsupported,
    }
}

fn exchangePosix(a: []const u8, b: []const u8) Error!void {
    if (std.mem.eql(u8, a, b)) assert.panic("swapping '{s}' with itself; exchange() must refuse that before calling exchangePosix()", .{a});
    var a_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    var b_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const a_z = try terminated(&a_buffer, a);
    const b_z = try terminated(&b_buffer, b);
    const at = std.posix.AT.FDCWD;
    const failed = switch (builtin.os.tag) {
        .linux => std.os.linux.errno(std.os.linux.renameat2(at, a_z, at, b_z, .{ .EXCHANGE = true })) != .SUCCESS,
        .macos => std.c.renameatx_np(at, a_z, at, b_z, .{ .SWAP = true }) != 0,
        else => assert.panic("exchangePosix() ran on {t}; exchange() must send other systems elsewhere", .{builtin.os.tag}),
    };
    if (failed) return error.ExchangeFailed;
    if (a_z.len != a.len or b_z.len != b.len) assert.panic("passed '{s}' and '{s}' to the system as {d} and {d} bytes; terminated() must copy each path whole", .{ a, b, a_z.len, b_z.len });
}

/// `path` copied into `buffer` with the terminating zero the system calls need.
fn terminated(buffer: *[std.fs.max_path_bytes:0]u8, path: []const u8) Error![:0]const u8 {
    if (path.len >= buffer.len) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) assert.panic("the path '{s}' holds a zero byte; --fix only replaces files it read by name", .{path});
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const copied = buffer[0..path.len :0];
    if (!std.mem.eql(u8, copied, path)) assert.panic("copied '{s}' as '{s}'; terminated() must copy the path unchanged", .{ path, copied });
    return copied;
}

extern "kernel32" fn ReplaceFileW(replaced: [*:0]const u16, replacement: [*:0]const u16, backup: ?[*:0]const u16, flags: u32, exclude: ?*anyopaque, reserved: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: [*:0]const u16, flags: u32) callconv(.winapi) std.os.windows.BOOL;

/// Windows has no exchange: `ReplaceFileW` puts `a` in place of `b` in one step and keeps what `b`
/// held as a backup, which is then given `a`'s name, free since `a` was just moved away.
fn exchangeWindows(a: []const u8, b: []const u8) Error!void {
    if (std.mem.eql(u8, a, b)) assert.panic("swapping '{s}' with itself; exchange() must refuse that before calling exchangeWindows()", .{a});
    const suffix = backup_suffix;
    if (a.len + suffix.len >= std.fs.max_path_bytes) return error.NameTooLong;
    var backup_bytes: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(backup_bytes[0..a.len], a);
    @memcpy(backup_bytes[a.len..][0..suffix.len], suffix);
    const backup = backup_bytes[0 .. a.len + suffix.len];
    var a_wide: [std.fs.max_path_bytes:0]u16 = undefined;
    var b_wide: [std.fs.max_path_bytes:0]u16 = undefined;
    var backup_wide: [std.fs.max_path_bytes:0]u16 = undefined;
    const a_w = try wide(&a_wide, a);
    const b_w = try wide(&b_wide, b);
    const backup_w = try wide(&backup_wide, backup);
    if (ReplaceFileW(b_w, a_w, backup_w, 0, null, null) == .FALSE) return error.ExchangeFailed;
    if (MoveFileExW(backup_w, a_w, 0) == .FALSE) {
        if (ReplaceFileW(b_w, backup_w, null, 0, null, null) == .FALSE) return error.OriginalKeptAsBackup;
        return error.ExchangeFailed;
    }
    if (backup.len <= a.len) assert.panic("the backup name '{s}' is no longer than '{s}'; it must add the suffix", .{ backup, a });
}

/// `path` as the zero-terminated UTF-16 the Windows calls take.
fn wide(buffer: *[std.fs.max_path_bytes:0]u16, path: []const u8) Error![:0]const u16 {
    if (path.len == 0) assert.panic("converting an empty path for Windows; exchange() must be given two paths", .{});
    const length = std.unicode.utf8ToUtf16Le(buffer, path) catch return error.ExchangeFailed;
    if (length >= buffer.len) return error.NameTooLong;
    buffer[length] = 0;
    if (length > path.len) assert.panic("'{s}' became {d} UTF-16 units from {d} bytes; UTF-8 never needs more units than bytes", .{ path, length, path.len });
    return buffer[0..length :0];
}

test "exchange swaps what two files hold" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "second" });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const dir = root[0..try tmp.dir.realPath(io, &root)];
    var a_path: [std.fs.max_path_bytes]u8 = undefined;
    var b_path: [std.fs.max_path_bytes]u8 = undefined;
    try exchange(try std.fmt.bufPrint(&a_path, "{s}/a", .{dir}), try std.fmt.bufPrint(&b_path, "{s}/b", .{dir}));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("second", try tmp.dir.readFile(io, "a", &buffer));
    try std.testing.expectEqualStrings("first", try tmp.dir.readFile(io, "b", &buffer));
}
