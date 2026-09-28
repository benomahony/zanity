const std = @import("std");
const assert = std.debug.assert;

fn bare(a: usize) void {
    assert(a > 0);
    std.debug.assert(a < 10);
}

fn explained(a: usize, ok: bool) void {
    if (!(a > 0)) std.debug.panic("expected a > 0, got a={d}", .{a});
    if (!ok) @panic("expected ok");
    if (a > 9) {
        std.debug.panic("expected a <= 9, got {d}", .{a});
    }
}

fn checked(xs: []const usize) void {
    for (xs) |x| if (!(x > 0)) std.debug.panic("expected every x > 0, got {d}", .{x});
    comptime if (!(@sizeOf(usize) > 0)) @panic("expected usize to have a size");
}
