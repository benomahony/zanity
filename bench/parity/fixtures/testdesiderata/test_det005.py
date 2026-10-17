import os


def test_token_has_length():
    assert len(os.urandom(8)) == 8
