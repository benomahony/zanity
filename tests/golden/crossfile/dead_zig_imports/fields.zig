const shared = @import("shared.zig");
const total = @import("shared.zig");

pub const Row = struct {
    total: u32,
    shared: shared.Total,
};

pub fn row() Row {
    return .{ .total = 1, .shared = 2 };
}
