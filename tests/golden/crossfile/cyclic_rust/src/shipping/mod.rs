mod parcel;
mod tariff;

use self::parcel::*;

pub fn ship(weight: u32) -> u32 {
    weigh(weight)
}
