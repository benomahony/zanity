import random
import time
from unittest.mock import MagicMock


def test_waits():
    time.sleep(1)
    while not ready():
        time.sleep(0.1)


def test_rolls():
    value = random.randint(1, 6)
    stamp = time.time()
    assert value, "rolled"


def test_fakes():
    fake = MagicMock()
    other = mock.Mock()


def helper():
    time.sleep(1)
    return random.random()
