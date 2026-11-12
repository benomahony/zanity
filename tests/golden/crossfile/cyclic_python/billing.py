from orders import place


def charge(amount):
    return amount


def refund(amount):
    return -amount


def rebill(order):
    place(order)
