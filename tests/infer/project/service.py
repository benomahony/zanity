def load(path):
    # judge: misleading-error
    if not path.endswith(".json"):
        raise FileNotFoundError(f"{path} does not exist")
    return open(path).read()


def parse(text):
    # judge: unconstructive-error
    if not text:
        raise ValueError(f"cannot parse {text!r}")
    return text.split()


def fail():
    raise ValueError("invalid input")


def fine(x):
    return x + 1


def test_loads_the_file():
    # judge: hollow-test
    load("data.json")


def test_waits_for_the_cache():
    time.sleep(1)
    assert parse("a b") == ["a", "b"], "splits on spaces"
