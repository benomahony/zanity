pub mod entry;

use entry::Line;

pub fn post(line: Line) -> u32 {
    line.amount
}

#[cfg(test)]
mod tests {
    use super::entry::Line;
    use crate::billing::refund;

    #[test]
    fn posts() {
        assert_eq!(super::post(Line { amount: refund(1) }), 1);
    }
}
