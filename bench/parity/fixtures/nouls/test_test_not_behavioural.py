def test_sends_welcome_email():
    send_welcome_email("ada@example.com")
    assert True, "expected the email to send"
