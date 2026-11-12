import { charge, refund } from "./billing";

export function place(order) {
  charge(order.total);
}

export function cancel(order) {
  refund(order.total);
}
