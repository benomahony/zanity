import asyncio


class Queue:
    def close(self) -> None:
        self.closed = True


class Session:
    def __init__(self) -> None:
        self._queue = Queue()

    async def flush(self) -> None:
        await asyncio.sleep(0)

    async def close(self) -> None:
        self._queue.close()
        self.flush()
