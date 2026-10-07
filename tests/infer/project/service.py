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


def test_parses_a_pair():
    text = "alpha beta"
    # judge: repeated-mechanics
    words = parse(text)
    assert len(words) == 2, f"expected 2 words, got {words!r}"
    assert words[0] == "alpha", f"expected alpha first, got {words!r}"
    assert words[1] == "beta", f"expected beta second, got {words!r}"


def test_parses_a_name():
    text = "ada lovelace"
    words = parse(text)
    assert len(words) == 2, f"expected 2 words, got {words!r}"
    assert words[0] == "ada", f"expected ada first, got {words!r}"
    assert words[1] == "lovelace", f"expected lovelace second, got {words!r}"


def test_parses_a_place():
    text = "new york"
    words = parse(text)
    assert len(words) == 2, f"expected 2 words, got {words!r}"
    assert words[0] == "new", f"expected new first, got {words!r}"
    assert words[1] == "york", f"expected york second, got {words!r}"
