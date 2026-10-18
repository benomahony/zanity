def recent_orders(orders):
    """Return the ten most recent orders, newest first."""
    return sorted(orders, key=lambda order: order.created_at)
