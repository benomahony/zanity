const std = @import("std");
const assert = std.debug.assert;

fn countdown(n: u32) u32 {
    assert(n < 100);
    assert(n >= 0);
    if (n == 0) return 0;
    return countdown(n - 1);
}

fn helper(n: u32) u32 {
    assert(n < 100);
    assert(n >= 0);
    return other.helper(n);
}
