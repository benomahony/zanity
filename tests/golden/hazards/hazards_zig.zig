const std = @import("std");

fn flagged(x: i64) i64 {
    std.crypto.hash.Md5.hash("x", undefined, .{});
    return std.time.milliTimestamp() - x;
}

fn quiet(x: i64) i64 {
    std.crypto.hash.sha2.Sha256.hash("x", undefined, .{});
    return x - 1;
}
