def doubled(values):
    out = []
    for value in values:
        out.append(value * 2)
    return out


def countdown(limit):
    out = []
    while limit > 0:
        out.append(limit)
        limit -= 1
    return out
