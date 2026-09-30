
def f(value: bool, other: bool) -> bool:
    assert isinstance(value, bool), "restates"  # zanity: ignore[NASA05-M1]
    assert isinstance(other, bool), "restates too"
    return value
