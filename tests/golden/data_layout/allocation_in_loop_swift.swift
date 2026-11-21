func total(rows: [[Int]]) -> Int {
    var sum = 0
    for row in rows.sorted(by: { $0.count < $1.count }) {
        let doubled = Array(row)
        sum += doubled.count
    }
    return sum
}
