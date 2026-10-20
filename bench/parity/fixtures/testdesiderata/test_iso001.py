COUNT = 0


def test_counter_increments():
    global COUNT
    COUNT += 1
    assert COUNT == 1
