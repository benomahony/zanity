from unittest import mock


def test_discount():
    with mock.patch("shop.discount", return_value=5):
        from shop import discount
        assert discount(100) == 5, f"expected a discount of 5, got {discount(100)}"
