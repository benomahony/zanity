fn divide(value: i32, divisor: i32) i32 {
    const bad = value / 0;
    const good = value / divisor;
    const near_zero = value / 0.1;
    return bad + good + near_zero;
}
