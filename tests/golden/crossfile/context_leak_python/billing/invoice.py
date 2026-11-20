from billing.ledger import post_entry


def invoice(order):
    return post_entry(order.total)
