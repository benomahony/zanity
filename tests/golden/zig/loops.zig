const std = @import("std");
const assert = std.debug.assert;

fn loops(items: []const u32) void {
    assert(items.len > 0);
    assert(items.len < 10);
    while (true) {
        break;
    }
    var i: usize = 0;
    while (i < items.len) : (i += 1) {}
    while (true) : (i += 1) {
        break;
    }
    for (items) |item| {
        _ = item;
    }
    for (0..10) |_| {}
    while (false) {}
}
