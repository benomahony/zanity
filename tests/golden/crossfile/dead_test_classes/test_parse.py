def parse(text):
    return text.split()


class TestParse:
    def test_splits_on_spaces(self):
        assert parse("a b") == ["a", "b"], "splits on spaces"


class _UnusedHelper:
    pass
