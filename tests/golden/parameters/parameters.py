def total(prices, currency, rounding):
    result = sum(prices)
    return round(result, rounding)


def stub(value, other):
    pass


def uses_all(a, b):
    first = a + 1
    return first * b


class Shape:
    def area(self, scale, _unused):
        width = 2
        return width * scale


def outer(factor):
    def inner(x):
        return x * factor
    return inner
