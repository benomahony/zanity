import { trace, Span } from "@opentelemetry/api";

const tracer = trace.getTracer("billing");

function charge(id: string): string {
  const span = tracer.startSpan("charge");
  return id;
}

function refund(id: string): string {
  const span = tracer.startSpan("refund");
  try {
    return id;
  } finally {
    span.end();
  }
}

function activeUnended(id: string): void {
  tracer.startActiveSpan("activeUnended", (span) => {
    console.log(id);
  });
}

function active(id: string): void {
  tracer.startActiveSpan("active", (span) => {
    console.log(id);
    span.end();
  });
}

function handedBack(): Span {
  return tracer.startSpan("handedBack");
}

const lazy = () => tracer.startSpan("lazy");

class Job {
  span?: Span;

  begin(): void {
    this.span = tracer.startSpan("job");
  }
}

function templated(id: string): void {
  const span = tracer.startSpan(`charge ${id}`);
  span.end();
}

function concatenated(id: string): void {
  const span = tracer.startSpan("charge " + id);
  span.end();
}

function firstOfTwo(id) {
  const first = tracer.startSpan("first");
  const second = tracer.startSpan("second");
  first.end();
  return id;
}

function otherEnded(id, timer) {
  const span = tracer.startSpan("otherEnded");
  timer.end();
  return id;
}

function finished(id) {
  const span = tracer.startSpan("finished");
  finish(span);
  return id;
}

class Keeper {
  keep() {
    const span = tracer.startSpan("keep");
    this.span = span;
  }
}
