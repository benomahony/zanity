import Testing
import XCTest

final class ConstantSwiftTests: XCTestCase {
    func testRejectsConstantChecks() {
        XCTAssertTrue(true) // parity: constant
        XCTAssertEqual(2, 1 + 1) // parity: constant
        XCTAssertEqual("abc", "abc", "strings match") // parity: constant
        let actual = calculate()
        XCTAssertEqual(2, actual)
        XCTAssertEqual(actual, 2)
        XCTAssertTrue(calculate() == 2)
        if unexpected() { XCTAssertTrue(false) }
        XCTAssertEqual("\(actual)", "2")
    }

    func helper() { XCTAssertEqual(2, 2) }
}

@Test func rejectsConstantExpectations() {
    #expect(1 + 1 == 2) // parity: constant
    #expect(calculate() == 2)
}
