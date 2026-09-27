
def f(x):
    assert x is not True, "not the sentinel"
    assert isinstance(x, int), "x must be int"
    return x
