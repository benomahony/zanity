const std = @import("std");

fn doubled(gpa: std.mem.Allocator, values: []const u32) !std.ArrayList(u32) {
    var out: std.ArrayList(u32) = .empty;
    for (values) |value| try out.append(gpa, value * 2);
    return out;
}

fn sizedDoubled(gpa: std.mem.Allocator, values: []const u32) !std.ArrayList(u32) {
    var out: std.ArrayList(u32) = .empty;
    try out.ensureTotalCapacity(gpa, values.len);
    for (values) |value| try out.append(gpa, value * 2);
    return out;
}
