def ready(count):
    assert count == 5
    return count


def checked(count):
    assert count == 5, f"expected 5 workers before starting, got {count}"
    return count
