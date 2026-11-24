const std = @import("std");

pub fn connect(api_token: []const u8) void {
    std.log.info("connecting with {s}", .{api_token});
}

pub fn connectTo(host: []const u8) void {
    std.log.info("connecting to {s}", .{host});
}
