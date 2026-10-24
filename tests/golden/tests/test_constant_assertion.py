def test_language_arithmetic():
    assert 1 + 1 == 2, "one plus one is two"
    assert True, "always true"


def test_real_behaviour():
    assert add(1, 1) == 2, "addition returns two"
    result = add(1, 1)
    assert result == 2, "result is two"
    assert f"{result}" == "2", "formatted result is two"


def helper():
    assert 1 + 1 == 2


def test_rejects_unexpected_branch():
    if unexpected():
        assert False, "must not reach this branch"
