
def f(value: bool) -> bool:
    assert isinstance(value, bool), "restates"  # nasa: ignore[NASA05-M1]
    assert value in (True, False), "real check"
    return value
