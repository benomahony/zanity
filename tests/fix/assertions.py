def f(a, b):
    assert len(a) > b.size
    assert a, "already explained"
    assert True


def g(q):
    assert len({e["id"] for e in q}) == len(q)
