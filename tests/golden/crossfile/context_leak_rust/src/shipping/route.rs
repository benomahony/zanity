use crate::billing::post_entry;

pub fn route(cost: u32) -> u32 {
    post_entry(cost)
}
