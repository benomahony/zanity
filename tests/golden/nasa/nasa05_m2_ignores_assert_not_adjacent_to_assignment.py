
def f(y):
    x = 5
    y = do(x)
    assert y is not None, "y comes from external call"
    return y
