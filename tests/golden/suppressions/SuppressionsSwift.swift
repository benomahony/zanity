@preconcurrency import Foundation

// swiftlint:disable force_cast
func cast(_ value: Any) -> Int {
    return value as! Int
}
// swiftlint:enable force_cast

func read() -> Data? {
    try? Data(contentsOf: url) // swiftlint:disable:this force_try
}

// periphery:ignore
func unused() {}

func run() {
    // The swiftlinter package is not a marker.
    print("swiftlint:disable is only text here")
}

final class Store: @unchecked Sendable {}

final class Cache: Sendable {}

@MainActor func render() {}
