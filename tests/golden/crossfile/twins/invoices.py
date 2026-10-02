def sum_invoices(invoices, tax):
    result = 0
    for invoice in invoices:
        if invoice.settled:
            result += invoice.value * tax
    return round(result, 2)


def different(items):
    count = len(items)
    names = [i.name for i in items]
    print(count, names)
    return names
