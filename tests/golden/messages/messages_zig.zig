const std = @import("std");

fn f(a: usize, b: usize) void {
    if (!(a > b)) std.debug.panic("expected a > b, got a={any}, b={any}", .{ a, b });
    if (a == 0) @panic("a must be positive");
    if (b > 10) std.debug.panic("b is {d}; the table only has 10 slots, so raise table_size", .{b});
    if (b == 3) @panic("OutOfMemory");
}
