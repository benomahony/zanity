import requests


def test_service_answers():
    assert requests.get('https://example.com').ok
