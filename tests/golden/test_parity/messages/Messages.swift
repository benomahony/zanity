// FIXME: this accepts expired credentials.
func compare(_ a: Int, _ b: Int) -> Int {
    assert(a > b, "expected a > b")
    if a > 10 {
        fatalError("invalid input")
    }
    if b > 10 {
        fatalError("ERR_TOO_BIG")
    }
    precondition(a >= 0, "a must not be negative, since it counts retries, got \(a)")
    return a - b
}
