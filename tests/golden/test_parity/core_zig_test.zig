const std = @import("std");
test "reaches real resources" {
    std.Thread.sleep(1); // parity: sleep-in-test
    while (ready()) { // parity: polling-loop
        std.Thread.sleep(1); // parity: sleep-in-test
    }
    _ = std.crypto.random.int(u8); // parity: nondeterministic-test
    _ = std.fs.cwd(); // parity: filesystem-in-test
    _ = std.net.tcpConnectToHost(allocator, "host", 80); // parity: network-in-test
    _ = std.process.spawn(io, options); // parity: process-in-test
    _ = std.Io.File.stdin(); // parity: stdin-in-test
}
fn helper() void {
    std.Thread.sleep(1);
    _ = std.fs.cwd();
}
