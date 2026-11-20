func doubled(values: [Int]) -> [Int] {
    var out: [Int] = []
    for value in values {
        out.append(value * 2)
    }
    return out
}

func sizedDoubled(values: [Int]) -> [Int] {
    var out: [Int] = []
    out.reserveCapacity(values.count)
    for value in values {
        out.append(value * 2)
    }
    return out
}
