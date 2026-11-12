import { place } from "./orders.js";

export function charge(amount: number): number {
  return amount;
}

export function refund(amount: number): number {
  return -amount;
}

export function rebill(order: { total: number }): void {
  place(order);
}
