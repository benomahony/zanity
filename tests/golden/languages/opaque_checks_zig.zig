const std = @import("std");

test "total includes tax" {
    try std.testing.expect(total() == 110);
}

test "receipt names the shop" {
    try std.testing.expect(std.mem.eql(u8, receipt(), "Shop"));
}

test "total is not zero" {
    try std.testing.expect(total() != 0);
}

test "total reads plainly" {
    try std.testing.expectEqual(110, total());
}
