import XCTest

final class OpaqueChecksTests: XCTestCase {
    func testComparesOpaquely() {
        let total = sum([1, 2])
        XCTAssertTrue(total == 3)
        XCTAssert(total != 4)
        XCTAssertFalse(total < 2)
        XCTAssertTrue(total >= 3, "total is at least three")
        XCTAssertTrue(owner === other)
        XCTAssertTrue(total == 3 && ready)
        XCTAssertTrue(ready)
        XCTAssertEqual(total, 3)
        XCTAssertTrue(items.contains(3))
    }
}
