def ship(orders):
    for order in orders:
        order.ship()


def ship_counted(orders, log):
    for order in orders:
        order.ship()
        log.record(order)


def totals(rows):
    out = 0
    for row in rows:
        out += row.customer.balance
    return out
