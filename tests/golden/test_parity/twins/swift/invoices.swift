func invoiceTotal(_ items: [Int], _ rate: Int) -> Int {
    var total = 0
    for item in items {
        if item > 10 {
            total += item * rate
        } else {
            total += item
        }
    }
    return total
}
