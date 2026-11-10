const std = @import("std");
const tested = @import("shared.zig");

test {
    std.testing.refAllDecls(@This());
}
