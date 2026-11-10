const std = @import("std");
const shared = @import("shared.zig");
const Total = shared.Total;
const Allocator = std.mem.Allocator;
pub const Exported = @import("shared.zig");

pub fn sum(values: []const u32) u32 {
    var total: u32 = 0;
    for (values) |value| total += value;
    std.debug.assert(total >= values.len);
    return total;
}
