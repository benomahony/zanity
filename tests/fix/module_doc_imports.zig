//! Names the separator paths use on this platform.
const unused = @import("std");
const std = @import("std");

pub fn separator() []const u8 {
    return std.fs.path.sep_str;
}
