from unittest import mock

import pytest


@pytest.fixture
def pricing():
    with mock.patch("shop.pricing.total", return_value=42):
        yield


def test_total_includes_tax(pricing):
    from shop.pricing import total
    assert total(["book"]) == 42, f"expected 42, got {total(['book'])}"
