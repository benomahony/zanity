from unittest.mock import MagicMock


def test_sends_the_receipt():
    mailer = MagicMock()
    checkout(mailer)
    mailer.send.assert_called_once_with("receipt")
    mailer.close.assert_not_called()


def test_totals_the_basket():
    assert total([1, 2]) == 3, "sums the prices"


def assert_called_like_a_helper(mock):
    mock.assert_called()
