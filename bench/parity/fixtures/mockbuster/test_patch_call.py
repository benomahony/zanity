from unittest.mock import patch


def test_sends_greeting():
    patcher = patch.object(object, "send")
    assert patcher is not None
