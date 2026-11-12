use crate::journal::record;
use crate::ledger::post;

pub struct Line {
    pub amount: u32,
}

pub fn repost(line: Line) -> u32 {
    record(&line) + post(line)
}
