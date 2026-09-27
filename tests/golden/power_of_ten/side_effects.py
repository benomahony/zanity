def consume(items, stream):
    assert items.pop() > 0, "pops while checking"
    assert (n := len(items)) > 0, "binds while checking"
    assert next(stream), "advances while checking"
    assert len(items) > 0, "reads only"
    assert items[0].startswith("a"), "reads only"
    return n
