def test_x():
    a = f(3, [1, 0, 2], {"k": 9})
    b = g(a)[1][0]
    assert b == 7 and a[2] > 0, f"expected 7, got {b}"
