def test_invoice_total():
    db = Database("postgres://localhost/test")
    db.migrate()
    customer = db.customers.create(name="Ada", country="UK", tier="gold")
    product = db.products.create(name="Book", price=10, tax_band="zero")
    warehouse = db.warehouses.create(name="North", country="UK")
    db.stock.create(product=product, warehouse=warehouse, quantity=5)
    order = db.orders.create(customer=customer)
    db.order_lines.create(order=order, product=product, quantity=2)
    invoice = Invoicer(db, TaxTable.load("uk"), Currency("GBP")).invoice(order)
    assert invoice.total == 20, f"expected 20, got {invoice.total}"
