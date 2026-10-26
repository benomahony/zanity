import Testing
import XCTest

final class ExpectedErrorsTests: XCTestCase {
    func testRejectsAnyError() {
        XCTAssertThrowsError(try parse("x"))
        XCTAssertThrowsError(try parse("x"), "parsing fails")
    }

    func testRejectsTheRightError() {
        XCTAssertThrowsError(try parse("x")) { error in
            XCTAssertEqual(error as? ParseError, .badInput)
        }
        XCTAssertThrowsError(try parse("x"), "parsing fails", { error in XCTAssertTrue(error is ParseError) })
    }
}

@Test func expectsAnyError() {
    #expect(throws: Error.self) { try parse("x") }
    #expect(throws: (any Error).self) { try parse("x") }
}

@Test func expectsTheRightError() {
    #expect(throws: ParseError.badInput) { try parse("x") }
    #expect(throws: ParseError.self) { try parse("x") }
}
