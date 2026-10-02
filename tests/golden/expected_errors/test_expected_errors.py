import unittest

import pytest


def test_rejects_negative_amounts():
    with pytest.raises(Exception):
        withdraw(-1)


def test_rejects_unknown_accounts():
    with pytest.raises(KeyError, match="no account"):
        withdraw_from("nobody", 1)


class TestAccount(unittest.TestCase):
    def test_rejects_overdraft(self):
        with self.assertRaises(BaseException):
            withdraw(10**9)

    def test_rejects_zero(self):
        with self.assertRaises(ValueError):
            withdraw(0)
