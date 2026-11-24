import Tracing
import Vapor

func refund(req: Request) async throws -> String {
    return "refunded"
}

func charge(req: Request) async throws -> String {
    return try await withSpan("charge") { span in
        return "charged"
    }
}

func cached(_ cache: Cache) async throws -> String? {
    return try await cache.get("orders", as: String.self)
}
