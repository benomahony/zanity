def test_saves_order(cursor, orders):
    orders.save({"id": 1})
    cursor.execute("SELECT id FROM orders")
    rows = cursor.fetchall()
    assert rows == [(1,)]


def test_saves_order_through_interface(orders):
    orders.save({"id": 1})
    assert orders.find(1) == {"id": 1}
