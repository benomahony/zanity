from .orders import place


def charge(order):
    return order


def rebill(order):
    return place(order)
