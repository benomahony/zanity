func total(_ order: Order) -> Int {
    var sum = order.lines.count()
    if order.lines.count() > 10 {
        sum += order.lines.count()
    }
    return sum
}

func ship(_ order: Order) -> String {
    let city = order.customer.address.city
    let name = order.customer.name
    return city + name
}

func narrow(_ flag: Bool) -> Int {
    let onlyInside = 3
    if flag {
        return onlyInside + 1
    }
    return 0
}

public func charge(_ amount: Int, _ unused: Int) -> Int {
    return amount * 2
}

public func refund(_ amount: Int) -> Int {
    return amount
}
