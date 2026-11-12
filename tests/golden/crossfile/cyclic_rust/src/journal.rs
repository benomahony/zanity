use crate::ledger::entry::Line;

pub fn record(line: &Line) -> u32 {
    line.amount
}
