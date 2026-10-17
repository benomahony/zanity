def greet(name: str) -> str:
    assert isinstance(name, str), "name must be a string"
    assert name, "name must not be empty"
    return "hello " + name
