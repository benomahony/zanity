def load(path):
    return path


def _helper(x):
    return x


def run(items):
    def model_fn(item):
        return item

    return [model_fn(i) for i in items]


def test_load():
    assert load("a") == "a", "load returns the path"
