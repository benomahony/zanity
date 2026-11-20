const std = @import("std");

fn initNames(gpa: std.mem.Allocator, count: usize) ![][]u8 {
    const names = try gpa.alloc([]u8, count);
    for (names) |*name| name.* = try gpa.alloc(u8, 8);
    return names;
}

fn labels(gpa: std.mem.Allocator, values: []const u32) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    for (values) |value| {
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{value}));
    }
    return out;
}

fn labelsInto(gpa: std.mem.Allocator, values: []const u32) !std.ArrayList(u32) {
    var out = try std.ArrayList(u32).initCapacity(gpa, values.len);
    for (values) |value| out.appendAssumeCapacity(value);
    return out;
}
