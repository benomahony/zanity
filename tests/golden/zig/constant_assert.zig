const std = @import("std");
const assert = std.debug.assert;

fn f(input: ?u32) void {
    const ready = true;
    assert(ready);
    var count: u32 = 5;
    assert(count == 5);
    const maybe: ?u32 = 7;
    assert(maybe != null);
    const other = input;
    assert(other != null);
    count = 3;
    assert(count == 4);
}
