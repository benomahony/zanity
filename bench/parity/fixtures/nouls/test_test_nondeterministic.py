import random


def test_shuffle_keeps_items():
    items = list(range(10))
    random.shuffle(items)
    assert items[0] != 0, f"expected the shuffle to move the first item, got {items}"
