import pytest


def test_rejects_negative():
    with pytest.raises(Exception):
        int('-x')
