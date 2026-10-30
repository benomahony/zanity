const { trace } = require("@opentelemetry/api");

const tracer = trace.getTracer("billing");

function charge(id) {
  const span = tracer.startSpan("charge");
  return id;
}

function refund(id) {
  const span = tracer.startSpan("refund");
  try {
    return id;
  } finally {
    span.end();
  }
}

function activeUnended(id) {
  tracer.startActiveSpan("activeUnended", (span) => {
    console.log(id);
  });
}

function active(id) {
  tracer.startActiveSpan("active", (span) => {
    console.log(id);
    span.end();
  });
}

function handedBack() {
  return tracer.startSpan("handedBack");
}

const lazy = () => tracer.startSpan("lazy");

class Job {
  begin() {
    this.span = tracer.startSpan("job");
  }
}

function templated(id) {
  const span = tracer.startSpan(`charge ${id}`);
  span.end();
}

function concatenated(id) {
  const span = tracer.startSpan("charge " + id);
  span.end();
}
