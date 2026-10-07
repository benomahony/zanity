import pytest


class Base:
    def handle(self, request, context):
        return request


class Handler(Base):
    def handle(self, request, context):
        reply = "ok"
        return reply


@pytest.fixture
def database(tmp_path, request):
    path = tmp_path / "db"
    return path


def model_fn(messages, info):
    reply = "hi"
    return reply


def run(agent_factory):
    return agent_factory(model_fn)


def unused_flag(items, flag):
    count = len(items)
    return count
