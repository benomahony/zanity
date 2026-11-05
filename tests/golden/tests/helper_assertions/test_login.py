def make_user(name):
    return [name]


def test_signs_in():
    assert make_user("ada") == ["ada"]


def test_signs_out():
    make_user("ada")
