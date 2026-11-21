import Tracing
import Vapor

func routes(_ app: Application) throws {
    app.get("orders", ":id") { req in
        return "order"
    }
    app.post("orders") { req in
        return try await withSpan("create_order") { span in
            return "created"
        }
    }
    app.post("refunds", use: refund)
    app.post("charges", use: charge)
}
