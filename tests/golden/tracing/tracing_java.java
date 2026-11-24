import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;

class Orders {
    private Span current;

    void forgotten(Tracer tracer) {
        Span span = tracer.spanBuilder("forgotten").startSpan();
        span.setAttribute("order", 1);
    }

    void ended(Tracer tracer) {
        Span span = tracer.spanBuilder("ended").startSpan();
        span.end();
    }

    Span returned(Tracer tracer) {
        return tracer.spanBuilder("returned").startSpan();
    }

    void stored(Tracer tracer) {
        Span span = tracer.spanBuilder("stored").startSpan();
        this.current = span;
    }

    void named(Tracer tracer, String id) {
        Span span = tracer.spanBuilder(String.format("order %s", id)).startSpan();
        span.end();
    }
}
