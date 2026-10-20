def test_cart_total():
    cart = Cart()
    cart.add("book", 10)
    assert cart._items == [("book", 10)], f"expected the private list to hold the book, got {cart._items}"
    assert cart._cache_valid is False, "expected the private cache to be invalid"
