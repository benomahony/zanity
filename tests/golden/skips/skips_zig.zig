const builtin = @import("builtin");

test "off" {
    return error.SkipZigTest;
}

test "only on linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
}
