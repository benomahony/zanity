const std = @import("std");
const assert = std.debug.assert;

fn consume(list: *std.ArrayList(u32), it: *std.mem.TokenIterator(u8, .scalar)) void {
    assert(list.pop() != null);
    assert(it.next() != null);
    assert(list.items.len > 0);
    assert(std.mem.eql(u8, "a", "a"));
}
