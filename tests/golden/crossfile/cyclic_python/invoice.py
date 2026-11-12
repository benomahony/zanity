from tariff import base
from tariff import surcharge


def total(amount):
    return base(amount) + surcharge(amount)
