import { place } from "./orders.js";

export function charge(amount) {
  return amount;
}

export function refund(amount) {
  return -amount;
}

export function rebill(order) {
  place(order);
}
