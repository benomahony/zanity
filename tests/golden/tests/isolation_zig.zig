const std = @import("std");

test "reaches out" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "out.txt", .data = "ok" });
    _ = std.fs.cwd();
    _ = std.process.Child.init(&.{"ls"}, std.testing.allocator);
    _ = try std.net.tcpConnectToHost(std.testing.allocator, "example.com", 80);
}

fn helper() void {
    _ = std.fs.cwd();
}
