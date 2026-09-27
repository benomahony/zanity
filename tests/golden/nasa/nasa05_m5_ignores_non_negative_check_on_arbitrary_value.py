
def f(x):
    n = compute(x)
    assert n >= 0, "compute may return a negative value"
    return n
