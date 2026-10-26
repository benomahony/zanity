import XCTest

final class EagerTest: XCTestCase {
    func testMany() {
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
    }

    func testEnough() {
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
        XCTAssertEqual(1, 1)
    }
}
