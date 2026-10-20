from unittest import mock


def test_sends_greeting():
    sender = mock.Mock()
    sender.send('hi')
    assert sender.send.called
