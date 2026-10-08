fn divide(value: i32, divisor: i32) -> i32 {
    let bad = value / 0;
    let good = value / divisor;
    let near_zero = value / 0.1;
    bad + good + near_zero
}
