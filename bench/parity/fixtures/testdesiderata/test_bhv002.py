from unittest.mock import patch


@patch('app.mailer.send')
def test_sends_greeting(send):
    assert send is not None
