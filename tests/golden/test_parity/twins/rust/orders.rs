pub fn order_total(items: &[u32], rate: u32) -> u32 {
    let mut total = 0;
    for item in items {
        if *item > 10 {
            total += item * rate;
        } else {
            total += item;
        }
    }
    total
}
