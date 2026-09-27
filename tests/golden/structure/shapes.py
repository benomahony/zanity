def many(a, b, c, d, e):
    return a


def four(a, b, c, d):
    return a


class C:
    def method(self, a, b, c, d):
        return a


def forward(x):
    return target(x)


def forward_call(x):
    target(x)


def documented(x):
    """Forwards."""
    return target(x)


def real(x):
    y = x + 1
    return target(y)


def handlers():
    try:
        risky()
    except ValueError:
        pass
    try:
        risky()
    except Exception:
        ...
    try:
        risky()
    except KeyError as error:
        log(error)
