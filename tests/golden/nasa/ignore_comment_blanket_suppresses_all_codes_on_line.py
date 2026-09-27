
def f(value: bool) -> bool:
    assert isinstance(value, bool), "restates"  # nasa: ignore
    assert value in (True, False), "real check"
    return value
