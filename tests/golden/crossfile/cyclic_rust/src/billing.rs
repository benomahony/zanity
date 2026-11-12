use crate::orders::place;
use crate::Config;
use std::fmt;

pub fn charge(config: &Config, amount: u32) -> u32 {
    amount * config.rate
}

pub fn refund(amount: u32) -> u32 {
    amount
}

pub fn rebill(amount: u32) -> u32 {
    place(amount)
}

pub fn show(f: &mut fmt::Formatter<'_>) -> fmt::Result {
    write!(f, "billing")
}
