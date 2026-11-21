def totals(rows):
    out = 0
    for row in rows:
        out += row.customer.balance
    return out


def direct(rows):
    out = 0
    for row in rows:
        out += row.balance
    return out
