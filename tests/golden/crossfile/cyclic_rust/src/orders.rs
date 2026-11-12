use crate::billing::{charge, refund};
use crate::Config;

pub fn place(amount: u32) -> u32 {
    charge(&Config { rate: 1 }, amount) + refund(amount)
}
