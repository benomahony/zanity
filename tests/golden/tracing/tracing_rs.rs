use opentelemetry::trace::Tracer;

fn named(tracer: &impl Tracer, id: u32) {
    let _span = tracer.start(format!("order {}", id));
}

fn fixed(tracer: &impl Tracer) {
    let _span = tracer.start("order");
}
