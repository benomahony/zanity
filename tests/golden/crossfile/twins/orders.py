def total_orders(orders, rate):
    total = 0
    for order in orders:
        if order.paid:
            total += order.amount * rate
    return round(total, 2)
