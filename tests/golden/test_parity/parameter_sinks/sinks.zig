const std = @import("std");

pub fn open(path: []const u8) !std.fs.File {
    return std.fs.openFileAbsolute(path, .{});
}

pub fn openFixed() !std.fs.File {
    return std.fs.openFileAbsolute("/etc/orders.conf", .{});
}
