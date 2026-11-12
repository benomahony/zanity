from billing import charge, refund


def place(order):
    charge(order.total)


def cancel(order):
    refund(order.total)
