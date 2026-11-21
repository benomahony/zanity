import { Request, Response } from "express";
import { trace } from "@opentelemetry/api";

const tracer = trace.getTracer("handlers");

export function refund(req: Request, res: Response): void {
  res.json({ refunded: true });
}

export function charge(req: Request, res: Response): void {
  const span = tracer.startSpan("charge");
  res.json({ charged: true });
  span.end();
}
