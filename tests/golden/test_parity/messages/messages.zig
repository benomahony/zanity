const std = @import("std");

// FIXME: this accepts expired credentials.
pub fn compare(a: i32, b: i32) i32 {
    if (a > 10) std.debug.panic("invalid input", .{});
    if (a < 0) std.debug.panic("a must not be negative, since it counts retries, got {d}", .{a});
    return a - b;
}
