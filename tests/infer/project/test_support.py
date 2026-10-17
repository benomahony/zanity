import pytest


@pytest.fixture
def shared_environment():
    # judge: fixture-leaks-state
    # judge: fixture-hides-behaviour
    return "patched"
