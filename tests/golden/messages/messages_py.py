import logging


def f(a, b, items):
    assert a > b, "expected a > b"
    assert a > 0, "a must be positive"
    assert len(items) > 0, f"items is empty; pass at least one path, got {items!r}"
    assert b, "assertion failed"
    if not items:
        raise ValueError("invalid input")
    if a < 0:
        raise ValueError("ERR_NEGATIVE")
    if b is None:
        raise ValueError("")
    logging.error("Something went wrong")
    raise RuntimeError(f"cannot open {a}: check the path exists and is readable")
