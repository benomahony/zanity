import XCTest

final class CoreSwiftTests: XCTestCase {
    func testReachesRealResources() throws {
        Thread.sleep(forTimeInterval: delay) // parity: sleep-in-test
        while !ready() { // parity: polling-loop
            sleep(1) // parity: sleep-in-test
        }
        _ = UUID() // parity: nondeterministic-test
        _ = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        _ = Date(timeIntervalSince1970: 0)
        _ = FileManager.default.contents(atPath: "config") // parity: filesystem-in-test
        _ = FileManager.default.contents(atPath: FileManager.default.temporaryDirectory.path)
        URLSession.shared.dataTask(with: url) // parity: network-in-test
        _ = Process() // parity: process-in-test
        _ = readLine() // parity: stdin-in-test
    }

    func helper(_ delay: Double) { Thread.sleep(forTimeInterval: delay); _ = readLine() }
}

func testLooksLikeATestOutsideAnyClass() { sleep(1) }
