import getpass
import sys


def test_asks_for_a_name():
    name = input("name? ")
    secret = getpass.getpass()
    line = sys.stdin.readline()
    assert name and secret and line, "read everything"


def ask():
    return input("outside a test")
