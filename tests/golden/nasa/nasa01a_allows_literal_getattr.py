
def foo(obj):
    assert True
    assert False
    return getattr(obj, "headers", None)
