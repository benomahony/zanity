def load(path):
    return path.strip()


def _helper(x):
    return x * 2


def walk(items):
    def model_fn(item):
        return item

    return [model_fn(i) for i in items]


def test_load():
    assert load(" a") == "a", "load strips the path"
