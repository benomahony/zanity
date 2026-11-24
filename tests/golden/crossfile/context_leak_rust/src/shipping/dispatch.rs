use crate::billing::ledger::post_entry;

pub fn dispatch(cost: u32) -> u32 {
    post_entry(cost)
}
