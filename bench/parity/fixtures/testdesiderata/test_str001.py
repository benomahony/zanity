def test_sends_greeting(sender):
    sender.send('hi')
    sender.send.assert_called_with('hi')
