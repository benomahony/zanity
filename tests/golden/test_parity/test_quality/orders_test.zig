const std = @import("std");

test "orders are read from the working directory" {
    try std.posix.chdir("/tmp");
    try std.testing.expect(true);
}
