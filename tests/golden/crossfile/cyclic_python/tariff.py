from invoice import total


def base(amount):
    return amount


def surcharge(amount):
    return amount // 10


def quote(amount):
    return total(amount)
