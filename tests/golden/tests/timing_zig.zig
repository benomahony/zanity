const std = @import("std");

test "waits" {
    std.Thread.sleep(1000);
    while (!ready()) {
        std.Thread.sleep(10);
    }
}

test "rolls" {
    const value = std.crypto.random.int(u8);
    const stamp = std.time.milliTimestamp();
    try std.testing.expect(value != stamp);
}

fn helper() void {
    std.Thread.sleep(1000);
}
