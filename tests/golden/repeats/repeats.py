def price_report(items, rate):
    total = 0
    for item in items:
        total += item.get("price", 0) * rate
        if item.get("price", 0) > 100:
            print("expensive", item.get("price", 0))
    return total


def drain(stack):
    first = stack.pop()
    second = stack.pop()
    third = stack.pop()
    return first, second, third


def parse(reader):
    first = reader.bytes[reader.at]
    reader.at += 1
    second = reader.bytes[reader.at]
    reader.at += 1
    third = reader.bytes[reader.at]
    return first, second, third


def fail_fast(db):
    if not db.open():
        return error_for(db.handle)
    if not db.ready():
        return error_for(db.handle)
    return error_for(db.handle)
