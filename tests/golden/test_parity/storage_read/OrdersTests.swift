import GRDB
import XCTest

final class OrdersTests: XCTestCase {
    var queue: DatabaseQueue!
    var orders: Orders!

    func testSavesOrder() throws {
        try orders.save(1)
        let rows = try queue.read { db in try Order.fetchAll(db) }
        XCTAssertEqual(rows.count, 1)
    }

    func testFindsOrder() throws {
        try orders.save(1)
        XCTAssertEqual(try orders.find(1), 1)
    }
}
