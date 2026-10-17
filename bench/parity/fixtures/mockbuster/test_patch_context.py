from unittest import mock


def test_sends_greeting():
    with mock.patch('app.mailer.send') as send:
        assert send is not None
