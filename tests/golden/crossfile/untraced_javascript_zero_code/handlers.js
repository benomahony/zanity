const { trace } = require("@opentelemetry/api");

const tracer = trace.getTracer("handlers");

function refund(req, res) {
  res.json({ refunded: true });
}

function charge(req, res) {
  const span = tracer.startSpan("charge");
  res.json({ charged: true });
  span.end();
}

module.exports = { refund, charge };
