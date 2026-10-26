@preconcurrency import Foundation
import Dispatch

public enum Settings {
    public static var retries = 3
    public static let timeout = 30
    static var cache: [String: Int] = [:]
    public static var label: String { "settings" }
    open class var region: String { "eu" }
}

struct Account: Hashable {
    let id: Int
    let name: String

    static func == (lhs: Account, rhs: Account) -> Bool { lhs.id == rhs.id }
}

struct Order: Hashable {
    let id: Int
    let note: String

    static func == (lhs: Order, rhs: Order) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Line: Equatable {
    let id: Int

    static func == (lhs: Line, rhs: Line) -> Bool { lhs.id == rhs.id }
}

final class Box: @unchecked Sendable {
    nonisolated(unsafe) static var shared = Box()
    nonisolated static func make() -> Box { Box() }
}

func spawn(_ work: @escaping @Sendable () -> Void) {
    Thread.detachNewThread { work() }
    Thread { work() }.start()
    let worker = Thread(target: Runner(), selector: #selector(Runner.run), object: nil)
    worker.start()
    DispatchQueue.global().async { work() }
    Task { work() }
    _ = Thread.current
}
