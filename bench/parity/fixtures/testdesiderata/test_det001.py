import random


def test_pick_returns_member():
    assert random.choice([1, 2]) in (1, 2)
