struct Padded {
    var ready: Bool
    var count: Int64
    var small: Bool
    static var shared: Int = 0
    var doubled: Int64 { count * 2 }
}

struct Ordered {
    var count: Int64
    var ready: Bool
    var small: Bool
}

struct Inferred {
    var ready = false
    var count: Int64
    var small: Bool
}
