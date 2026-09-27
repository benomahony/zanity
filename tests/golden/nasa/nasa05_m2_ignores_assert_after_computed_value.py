
def f():
    x = compute()
    assert x is not None, "compute may return None"
    return x
