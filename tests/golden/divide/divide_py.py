def divide(value, divisor):
    bad = value / 0
    good = value / divisor
    near_zero = value / 0.1
    return bad + good + near_zero
