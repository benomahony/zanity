class FallbackModel:
    pass


def fallback_model():
    return FallbackModel()


def now():
    return _now()


def _now():
    return 0


def tool_for(name):
    return name


def for_tool(name):
    return name
