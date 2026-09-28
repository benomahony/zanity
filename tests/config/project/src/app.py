def many(a, b, c, d, e):
    assert a > 0, f"a is {a}; many() needs a positive count, so pass at least 1"
    assert b is not None, f"b is None with a={a}; pass the name many() should use"
    return a
