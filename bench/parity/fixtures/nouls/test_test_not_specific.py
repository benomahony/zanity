def test_everything():
    order = place_order("ada", ["book"])
    assert order, "expected an order"
    assert order.id, "expected an id"
    assert order.items, "expected items"
    assert order.total, "expected a total"
    assert order.status, "expected a status"
