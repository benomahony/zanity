def log_all(*messages):
    return len(messages)


def configure(**options):
    return len(options)


def total(prices):
    return sum(prices)


class Handler(BaseHandler):
    def log_message(self, format, *args):
        return format % args


def traced(function):
    def wrapper(*args, **kwargs):
        return function(*args, **kwargs)

    return wrapper
