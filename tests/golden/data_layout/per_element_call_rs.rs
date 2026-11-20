struct Order;

impl Order {
    fn ship(&self) {}
}

fn ship(orders: &[Order]) {
    for order in orders {
        order.ship();
    }
}
