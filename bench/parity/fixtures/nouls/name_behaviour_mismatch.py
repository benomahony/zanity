def is_valid_order(order, db):
    order.status = "shipped"
    db.save(order)
    db.notify_warehouse(order.id)
    return True
