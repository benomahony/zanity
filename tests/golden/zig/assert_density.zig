const std = @import("std");
const assert = std.debug.assert;

fn none() void {}

fn one(x: u32) void {
    assert(x > 0);
}

fn two(x: u32) void {
    std.debug.assert(x > 0);
    assert(x < 10);
}

fn nested(x: u32) void {
    if (x > 0) {
        assert(x < 10);
        assert(x != 5);
    }
}

fn outer(x: u32) void {
    const Inner = struct {
        fn inner(y: u32) void {
            assert(y > 0);
            assert(y < 10);
        }
    };
    Inner.inner(x);
}

const Point = struct {
    x: u32,

    fn method(self: Point) void {
        assert(self.x > 0);
    }
};

test "tests are not functions" {
    try std.testing.expect(true);
}
