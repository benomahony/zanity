from billing.ledger import post_entry


def dispatch(parcel):
    post_entry(parcel.cost)
