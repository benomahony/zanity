def close_if_supported(stream):
    aclose = getattr(stream, "aclose", None)
    if aclose is not None:
        aclose()


def apply(handler, value):
    return handler(value)


class Stream:
    def aclose(self):
        close_if_supported(self.source)

    def handler(self, value):
        return apply(self.handler, value)

    def retry(self):
        return self.retry()
