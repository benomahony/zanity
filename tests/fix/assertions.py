def f(a, b):
    assert len(a) > b.size
    assert a, "already explained"
    assert True


def g(q):
    assert len({e["id"] for e in q}) == len(q)


def h(d, k, x):
    assert d['schema_version'] == '2.0'
    assert k in d and d[k] > 0
    assert x is None or x.ok
