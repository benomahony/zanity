const Order = struct {
    fn ship(self: *const Order) void {
        _ = self;
    }
};

fn ship(orders: []const Order) void {
    for (orders) |order| order.ship();
}
