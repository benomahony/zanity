const std = @import("std");
const assert = std.debug.assert;

fn f(a: []const u8, b: usize) void {
    assert(a.len > b);
    if (b > 0) assert(std.mem.eql(u8, a, "x{"));
    defer assert(b < 10);
    assert(true);
    if (!(b != 3)) std.debug.panic("expected b != 3, got {d}", .{b});
}
