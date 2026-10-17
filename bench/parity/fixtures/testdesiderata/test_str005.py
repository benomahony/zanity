def test_sends_greeting(sender):
    sender.send('hi')
    sender.send.assert_any_call('hi')
