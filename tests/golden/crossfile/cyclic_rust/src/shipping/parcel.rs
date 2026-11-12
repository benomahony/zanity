use super::tariff::rate;
use serde::Serialize;

pub fn weigh(weight: u32) -> u32 {
    weight * rate()
}

#[derive(Serialize)]
pub struct Label;
