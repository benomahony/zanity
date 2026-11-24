const std = @import("std");

pub fn stop(code: u8) void {
    std.process.exit(code);
}

pub fn main() void {
    std.process.exit(0);
}
