import Foundation
import XCTest

func countdown(_ n: Int) -> Int {
    precondition(n >= 0, "n must not be negative")
    assert(n < 100, "n must be small")
    return countdown(n - 1)
}

func emit(_ message: String) { emit(message, terminator: "\n") }

func emit(_ message: String, terminator: String) { print(message, terminator: terminator) }

func spin() {
    while true { }
    repeat { } while true
}

func bounded(_ items: [Int]) {
    for item in items {
        print(item)
    }
    _ = items[0]
}

func many(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ e: Int) -> Int {
    return a + b + c + d + e
}

func forward(_ x: Int) -> Int { target(x) }

func first(_ items: [Int]) -> Int { items[0] }

func ignore() {
    do {
        try work()
    } catch { }
    try? work()
    _ = try? work()
    do {
        try work()
    } catch {
        // The cache is rebuilt on the next launch.
    }
}

func checks(_ items: inout [Int]) {
    let ready = 5
    assert(ready == 5)
    assert(items.removeFirst() > 0, "removes while checking")
}

func guarded(_ name: String?, count: Int) {
    guard let name else { fatalError("name is required") }
    guard count >= 0 else { preconditionFailure("count must not be negative") }
    guard count < 10 else { return }
    print(name)
}

final class RulesTests: XCTestCase {
    func testWaits() {
        Thread.sleep(forTimeInterval: 1)
        _ = Int.random(in: 1...6)
        _ = mock(Store.self)
    }
}

struct Pattern {
    init(_ raw: String, strict: Bool) throws { }
    init?(lenient raw: String) { try? self.init(raw, strict: false) }
}
