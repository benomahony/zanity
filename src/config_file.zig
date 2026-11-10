//! Finding and reading the nearest zanity.toml, at or above the working directory and no higher
//! than the repository root.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = @import("assert.zig");
const Config = @import("config.zig").Config;
const file_name = @import("config.zig").file_name;
const max_file_bytes = @import("config.zig").max_file_bytes;
const parseConfig = @import("config_toml.zig").parseConfig;

/// The most directories searched upwards for zanity.toml, deeper than any real path.
const max_parent_dirs = 64;

/// Finds and reads the nearest `zanity.toml` at or above the current directory, stopping at
/// the repository root. No file means an empty config.
pub fn initConfig(gpa: Allocator, io: Io) !Config {
    const start = try Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    if (!std.fs.path.isAbsolute(start)) assert.panic("looking for {s} from '{s}', which is relative; pass the real path", .{ file_name, start });
    var dir: ?[]const u8 = start;
    for (0..max_parent_dirs) |_| {
        const d = dir orelse break;
        const path = try std.fs.path.join(gpa, &.{ d, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch null;
        if (bytes) |found| {
            var config = try parseConfig(found);
            config.dir = d;
            return config;
        }
        if (isRepositoryRoot(io, d)) break;
        dir = std.fs.path.dirname(d);
    }
    if (start.len == 0) assert.panic("searched for {s} from an empty directory; initConfig() must start from the real path of the working directory", .{file_name});
    return .{};
}

fn isRepositoryRoot(io: Io, dir: []const u8) bool {
    if (dir.len == 0) assert.panic("checking whether an empty path is a repository root; initConfig() must stop at the filesystem root before calling it", .{});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git = std.fmt.bufPrint(&buffer, "{s}/.git", .{dir}) catch return false;
    Io.Dir.cwd().access(io, git, .{}) catch return false;
    if (git.len <= dir.len) assert.panic("'{s}' is no longer than its directory '{s}'; isRepositoryRoot() must join .git onto the directory", .{ git, dir });
    return true;
}
