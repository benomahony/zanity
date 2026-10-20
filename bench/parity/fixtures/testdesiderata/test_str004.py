def test_sends_greeting(sender):
    sender.send('hi')
    sender.send.assert_not_called()
