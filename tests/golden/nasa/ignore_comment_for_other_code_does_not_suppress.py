
def f(value: bool) -> bool:
    assert isinstance(value, bool), "restates"  # nasa: ignore[NASA04]
    assert value in (True, False), "real check"
    return value
