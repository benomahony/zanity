import { charge, refund } from "./billing";

export function place(order: { total: number }): void {
  charge(order.total);
}

export function cancel(order: { total: number }): void {
  refund(order.total);
}
