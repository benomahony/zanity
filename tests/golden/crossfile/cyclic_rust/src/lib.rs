mod billing;
mod journal;
mod ledger;
mod orders;
mod shipping;

pub use billing::charge;

pub struct Config {
    pub rate: u32,
}
