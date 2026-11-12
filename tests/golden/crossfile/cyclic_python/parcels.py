from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from shipping import ship


def weigh(parcel):
    return parcel.weight
