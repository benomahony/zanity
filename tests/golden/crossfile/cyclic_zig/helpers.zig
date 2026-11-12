const std = @import("std");
const engine = @import("engine.zig");

pub fn split(n: u32) u32 {
    return n + engine.Limit;
}

pub fn join(n: u32) u32 {
    return n * engine.Limit + std.math.maxInt(u8);
}
