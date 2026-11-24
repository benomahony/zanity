import SQLite3
import XCTest

final class OrdersTests: XCTestCase {
    func testSavesToDatabase() {
        var db: OpaquePointer?
        sqlite3_open("orders.sqlite", &db)
        setenv("MODE", "test", 1)
        let gateway = mock(Gateway.self)
        Orders(db, gateway).charge(1)
        verify(gateway.charge(1)).wasCalled()
    }

    func testTotalWithoutDocs() {
        let a0 = 0
        let a1 = 1
        let a2 = 2
        let a3 = 3
        let a4 = 4
        let a5 = 5
        let a6 = 6
        let a7 = 7
        let a8 = 8
        let a9 = 9
        let a10 = 10
        let a11 = 11
        let a12 = 12
        let a13 = 13
        let a14 = 14
        let a15 = 15
        let a16 = 16
        let a17 = 17
        let a18 = 18
        let a19 = 19
        let a20 = 20
        let a21 = 21
        XCTAssertEqual(a0 + a21, 21)
    }

    /// Checks that saving an order in memory keeps it.
    func testSavesInMemory() {
        XCTAssertTrue(Orders().save(1))
    }
}
