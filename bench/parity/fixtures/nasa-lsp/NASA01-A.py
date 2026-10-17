def run(source: str) -> object:
    assert source, "source must not be empty"
    assert source.isprintable(), "source must be printable"
    return eval(source)
