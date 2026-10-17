def label(count: int) -> str:
    assert count >= 0, "count must not be negative"
    text = str(count)
    assert text, "text must not be empty"
    return text
