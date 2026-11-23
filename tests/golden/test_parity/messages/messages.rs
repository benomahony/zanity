// FIXME: this accepts expired credentials.
pub fn compare(a: i32, b: i32) -> i32 {
    assert!(a > b, "expected a > b");
    if a > 10 {
        panic!("invalid input");
    }
    if b > 10 {
        panic!("ERR_TOO_BIG");
    }
    assert!(a >= 0, "a must not be negative, since it counts retries, got {}", a);
    a - b
}
