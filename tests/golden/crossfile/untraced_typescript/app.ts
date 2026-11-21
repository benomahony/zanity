import express, { Request, Response } from "express";
import { trace } from "@opentelemetry/api";
import { refund, charge } from "./handlers";

const tracer = trace.getTracer("orders");
const app = express();
const prices = new Map<string, number>();

app.get("/orders/:id", (req: Request, res: Response) => {
  res.json({ id: req.params.id });
});

app.post("/orders", (req: Request, res: Response) => {
  tracer.startActiveSpan("create_order", (span) => {
    res.json(req.body);
    span.end();
  });
});

app.post("/refunds", refund);
app.post("/charges", charge);

export const small = prices.get("small");
export default app;
