const std = @import("std");
const shared = @import("shared.zig");
const Allocator = std.mem.Allocator;

pub fn describe(gpa: Allocator, total: shared.Total) ![]u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{total});
}
