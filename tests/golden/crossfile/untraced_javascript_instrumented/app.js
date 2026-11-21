const express = require("express");
const { trace } = require("@opentelemetry/api");
const { registerInstrumentations } = require("@opentelemetry/instrumentation");
const { ExpressInstrumentation } = require("@opentelemetry/instrumentation-express");

registerInstrumentations({ instrumentations: [new ExpressInstrumentation()] });

const tracer = trace.getTracer("orders");
const app = express();

app.get("/orders/:id", (req, res) => {
  res.json({ id: req.params.id });
});

module.exports = { app, tracer };
