class Queue:
    pass


class Session:
    def __init__(self) -> None:
        self._queue = Queue()

    def __rich_console__(self, console, options):
        return self.render(console, options)

    def render(self, console, options):
        yield self.text

    def total(self, values):
        total = sum(values)

async def fetch(url):
    await get(url)
