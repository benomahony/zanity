RESULTS = []


def test_adds_first_item():
    RESULTS.append("first")
    assert RESULTS == ["first"], f"expected one item, got {RESULTS}"


def test_adds_second_item():
    RESULTS.append("second")
    assert RESULTS == ["first", "second"], f"expected both items, got {RESULTS}"
