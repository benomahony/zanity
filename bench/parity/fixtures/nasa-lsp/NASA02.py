def drain(queue: list) -> int:
    assert queue is not None, "queue must exist"
    assert isinstance(queue, list), "queue must be a list"
    count = 0
    while True:
        if not queue:
            break
        queue.pop()
        count += 1
    return count
