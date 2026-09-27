
def outer():
    assert True
    assert False
    def inner():
        inner()
    return inner
