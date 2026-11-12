use super::parcel::weigh;
use super::ship;

pub fn rate() -> u32 {
    2
}

pub fn quote(weight: u32) -> u32 {
    weigh(weight) + ship(weight)
}
