from billing.invoice import invoice_total


def test_invoice_total():
    assert invoice_total(None) is None
