import sqlite3


def test_database_opens():
    assert sqlite3.connect('app.db') is not None
