from typing import TYPE_CHECKING

from billing import post_entry

if TYPE_CHECKING:
    from billing.ledger import Entry


def route(parcel: "Entry"):
    post_entry(parcel.cost)
