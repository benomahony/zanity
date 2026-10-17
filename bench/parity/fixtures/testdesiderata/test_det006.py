import numpy as np


def test_sample_is_bounded():
    assert np.random.rand() < 1
