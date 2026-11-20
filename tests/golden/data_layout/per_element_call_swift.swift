struct Order {
    func ship() {}
}

func ship(orders: [Order]) {
    for order in orders {
        order.ship()
    }
}
