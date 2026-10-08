import random


def configure_randomness():
    random.seed(7)


def configure_from_runtime(seed):
    random.seed(seed)


def test_reproducible_sequence():
    random.seed(7)
