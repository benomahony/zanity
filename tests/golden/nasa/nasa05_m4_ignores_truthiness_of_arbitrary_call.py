
def f(x):
    value = compute(x)
    assert value, "compute must return a truthy value"
    return value
