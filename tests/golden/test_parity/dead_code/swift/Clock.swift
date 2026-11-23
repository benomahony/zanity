protocol Clock {
    func now() -> Int
}

struct SystemClock: Clock {
    func now() -> Int {
        return 0
    }
}

protocol Store {
    func save(_ value: Int)
}

struct MemoryStore: Store {
    func save(_ value: Int) {}
}

struct DiskStore: Store {
    func save(_ value: Int) {}
}

public func api() -> Int {
    return helper()
}

private func helper() -> Int {
    return 1
}

private func forgotten() -> Int {
    return 2
}
