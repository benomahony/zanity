const std = @import("std");
const testing = std.testing;
test "rejects constant checks" {
    try std.testing.expect(true); // parity: constant
    try testing.expectEqual(2, 1 + 1); // parity: constant
    try std.testing.expectEqualStrings("abc", "abc"); // parity: constant
    try testing.expectEqualSlices(u8, "abc", "abc"); // parity: constant
    try testing.expectApproxEqAbs(1.0, 1.0, 0.01); // parity: constant
    const actual = calculate();
    try testing.expectEqual(2, actual);
    try testing.expectEqualSlices(u8, "abc", actual);
    try testing.expectApproxEqAbs(1.0, actual, 0.01);
    try testing.expectEqual(actual, 2);
    try testing.expect(calculate() == 2);
    if (unexpected()) std.debug.assert(false);
    try other.expectEqual(1, 1);
}
fn helper() !void {
    try testing.expectEqual(2, 2);
}
