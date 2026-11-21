const express = require("express");
const { trace } = require("@opentelemetry/api");
const { refund, charge } = require("./handlers");

const tracer = trace.getTracer("orders");
const app = express();
const prices = new Map();

app.get("/orders/:id", (req, res) => {
  res.json({ id: req.params.id });
});

app.post("/orders", (req, res) => {
  tracer.startActiveSpan("create_order", (span) => {
    res.json(req.body);
    span.end();
  });
});

app.post("/refunds", refund);
app.post("/charges", charge);

module.exports = { app, small: prices.get("small") };
