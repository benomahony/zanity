import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.instrumentation.annotations.WithSpan;

class OrderController {
    private final Tracer tracer = GlobalOpenTelemetry.getTracer("orders");

    @GetMapping("/orders/{id}")
    String order(String id) {
        return id;
    }

    @PostMapping("/orders")
    String create(String body) {
        Span span = tracer.spanBuilder("create").startSpan();
        span.end();
        return body;
    }

    @WithSpan
    @DeleteMapping("/orders/{id}")
    String delete(String id) {
        return id;
    }

    String total(String id) {
        return id;
    }
}
