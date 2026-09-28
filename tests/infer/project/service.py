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
