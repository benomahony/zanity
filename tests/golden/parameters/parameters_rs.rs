fn total(prices: &[i32], currency: &str) -> i32 {
    let sum: i32 = prices.iter().sum();
    sum
}

fn format(value: i32, _locale: &str) -> String {
    let text = value.to_string();
    text
}
