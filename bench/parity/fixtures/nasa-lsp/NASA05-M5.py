def size(items: list) -> int:
    assert items is not None, "items must exist"
    n = len(items)
    assert n >= 0, "length must not be negative"
    return n
