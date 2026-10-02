from unittest import mock
from unittest.mock import MagicMock, patch

import pytest
import requests


@pytest.fixture
def client():
    return MagicMock()


@patch("app.service.fetch")
def test_patched(fetch):
    assert fetch is not None, "patched"


@mock.patch.object(requests, "get")
def test_patched_object(get):
    assert get is not None, "patched"


def test_spied(mocker, monkeypatch):
    spy = mocker.spy(requests, "get")
    mocker.patch("app.service.fetch")
    monkeypatch.setattr(requests, "get", lambda url: None)
    monkeypatch.setenv("HOME", "/tmp")
    with patch("app.service.fetch"):
        assert spy is not None, "spied"


def test_real_http_verb(session):
    session.patch("/items/1", json={})
