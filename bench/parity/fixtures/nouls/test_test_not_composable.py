def test_pricing():
    assert price("book", "UK", "member", 2) == 18, "expected a member's two UK books to cost 18"
    assert price("book", "US", "guest", 1) == 12, "expected a guest's US book to cost 12"
    assert price("pen", "UK", "guest", 10) == 9, "expected ten UK pens to cost 9"
