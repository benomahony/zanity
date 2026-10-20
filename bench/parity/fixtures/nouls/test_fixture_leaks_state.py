import os

import pytest


@pytest.fixture
def production_mode():
    os.environ["APP_MODE"] = "production"
    return "production"


def test_reads_mode(production_mode):
    assert os.environ["APP_MODE"] == production_mode, f"expected {production_mode}, got {os.environ['APP_MODE']}"
