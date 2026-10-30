from opentelemetry import trace

tracer = trace.get_tracer(__name__)


def charge(order_id):
    span = tracer.start_span("charge")
    return order_id


def refund(order_id):
    span = tracer.start_span("refund")
    try:
        return order_id
    finally:
        span.end()


def scoped(order_id):
    with tracer.start_as_current_span("scoped"):
        return order_id


def scoped_manual(order_id):
    with tracer.start_span("scoped_manual") as span:
        return order_id


def handed_back():
    return tracer.start_span("handed_back")


class Job:
    def begin(self):
        self.span = tracer.start_span("job")


def formatted(order_id):
    with tracer.start_as_current_span(f"charge {order_id}"):
        return order_id


def concatenated(order_id):
    with tracer.start_as_current_span("charge " + order_id):
        return order_id
