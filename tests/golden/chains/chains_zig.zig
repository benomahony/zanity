const std = @import("std");

fn ship(order: Order) []const u8 {
    const city = order.customer.address.city;
    const same = std.mem.eql(u8, city, order.customer.name);
    _ = same;
    return city;
}
