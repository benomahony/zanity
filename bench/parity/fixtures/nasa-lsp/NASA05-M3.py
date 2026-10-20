def shout(text: object) -> str:
    assert text is not None, "text must exist"
    assert isinstance(text, str), "text must be a string"
    return text.upper()
