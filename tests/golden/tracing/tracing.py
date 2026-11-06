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


def used(order_id):
    span = tracer.start_span("used")
    with trace.use_span(span, end_on_exit=True):
        return order_id


def finished(order_id):
    span = tracer.start_span("finished")
    finish(span)
    return order_id


def collected(spans):
    spans.append(tracer.start_span("collected"))


def kept(job):
    span = tracer.start_span("kept")
    job.span = span


def paired(context):
    span = tracer.start_span("paired")
    return context, span


def first_of_two(order_id):
    first = tracer.start_span("first")
    second = tracer.start_span("second")
    first.end()
    return order_id


def other_ended(order_id, timer):
    span = tracer.start_span("other_ended")
    timer.end()
    return order_id


def discarded(order_id):
    tracer.start_span("discarded")
    return order_id


def dropped(order_id):
    span = tracer.start_span("dropped")
    span.set_attribute("order", order_id)
    return order_id
