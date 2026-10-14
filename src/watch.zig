//! `zanity check --watch`: what tells one look at the files from the next, and the command line
//! each rerun gets. Each rerun is a fresh `zanity check`, so nothing a run holds carries over,
//! and the cache makes the files that didn't change quick to check again.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;

/// How long to wait between looks at the files: quick enough that a rerun follows a save at
/// once, slow enough that looking costs nothing beside a check.
pub const poll_interval: Io.Duration = .fromMilliseconds(250);

/// Clears the terminal and its scrollback and moves to the top, so each run starts on a clean screen.
pub const clear_screen = "\x1b[2J\x1b[3J\x1b[H";

/// A hash of the path, size and modification time of each file in `groups`, so any edit, new
/// file, deletion or rename changes it. A file that can't be read hashes as missing.
pub fn fingerprint(io: Io, groups: []const []const []const u8) u64 {
    if (groups.len == 0) assert.panic("fingerprinting no groups of files, so no change could ever show; pass the files check reads", .{});
    var hash = std.hash.Wyhash.init(0);
    var missing: usize = 0;
    var files: usize = 0;
    for (groups) |group| for (group) |path| {
        files += 1;
        hash.update(path);
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
            hash.update("\x00missing");
            missing += 1;
            continue;
        };
        hash.update(std.mem.asBytes(&stat.size));
        hash.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    };
    if (missing > files) assert.panic("{d} of {d} files counted missing; each file is looked at once", .{ missing, files });
    return hash.final();
}

/// `args`, the command line after the program's name, without --watch, written into `out`
/// after `exe`, so each rerun checks once with every other option as given.
pub fn rerunArgs(out: [][]const u8, exe: []const u8, args: []const []const u8) []const []const u8 {
    if (out.len < args.len + 1) assert.panic("room for {d} arguments to rerun {d}; give rerunArgs() one more slot than the arguments", .{ out.len, args.len });
    if (exe.len == 0) assert.panic("rerunning zanity from an empty path; pass the path executablePathAlloc() found", .{});
    out[0] = exe;
    var len: usize = 1;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "--watch=true")) continue;
        out[len] = arg;
        len += 1;
    }
    return out[0..len];
}

test "a rerun keeps every option but --watch" {
    var out: [8][]const u8 = undefined;
    const argv = rerunArgs(&out, "/bin/zanity", &.{ "check", "src", "--watch", "--strict", "--watch=true" });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "/bin/zanity", "check", "src", "--strict" }), argv);
}

test "the fingerprint changes when a file it covers is written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = "x = 1\n" });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/a.py", .{tmp.sub_path});
    const before = fingerprint(io, &.{&.{path}});
    try std.testing.expectEqual(before, fingerprint(io, &.{&.{path}}));
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = "x = 12\n" });
    try std.testing.expect(before != fingerprint(io, &.{&.{path}}));
}
