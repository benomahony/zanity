import datetime


def test_stamp_is_recent():
    assert datetime.datetime.now().year > 2000
