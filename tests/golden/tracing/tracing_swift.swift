import Tracing

func charge(orderID: String) -> String {
    let span = InstrumentationSystem.tracer.startSpan("charge")
    return orderID
}

func refund(orderID: String) -> String {
    let span = InstrumentationSystem.tracer.startSpan("refund")
    defer { span.end() }
    return orderID
}

func unattached(orderID: String) -> String {
    let span = startSpan("unattached")
    return orderID
}

func scoped(orderID: String) -> String {
    return withSpan("scoped") { span in
        orderID
    }
}

func handedBack() -> any Span {
    return InstrumentationSystem.tracer.startSpan("handedBack")
}

final class Job {
    var span: (any Span)?

    func begin() {
        self.span = InstrumentationSystem.tracer.startSpan("job")
    }
}

func formatted(orderID: String) -> String {
    withSpan("charge \(orderID)") { span in
        orderID
    }
}
