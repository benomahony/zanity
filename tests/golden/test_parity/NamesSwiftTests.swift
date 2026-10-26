import Testing
import XCTest

final class NamesSwiftTests: XCTestCase {
    func test() { XCTAssertTrue(compute()) }
    func testRejectsExpiredTokens() throws {
        throw XCTSkip("temporarily disabled")
    }
    func testSkipsWithoutTheNetwork() throws {
        try XCTSkipIf(offline, "needs the network")
        XCTAssertTrue(compute())
    }
    func testOnlyOnLinux() throws {
        if !isLinux { throw XCTSkip("Linux only") }
        XCTAssertTrue(compute())
    }
    func testOnlyOnMacOS() throws {
        #if os(Linux)
        throw XCTSkip("macOS only")
        #endif
        XCTAssertTrue(compute())
    }
    override func setUpWithError() throws {
        throw XCTSkip("the whole suite is disabled")
    }
    func testAcceptsValidTokens() { XCTAssertTrue(compute()) }
}

@Test(.disabled("flaky on CI")) func rejectsRevokedTokens() { #expect(compute()) }
@Test(.disabled(if: offline)) func fetchesTokens() { #expect(compute()) }
@Test(.disabled(Platform.unsupportedReason)) func refreshesTokens() { #expect(compute()) }
@Test(.disabled()) func revokesTokens() { #expect(compute()) }
@Test func acceptsRenewedTokens() { #expect(compute()) }
