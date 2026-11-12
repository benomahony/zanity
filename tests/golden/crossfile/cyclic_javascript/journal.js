export { post } from "./ledger.js";

export function record(entry) {
  return entry.amount;
}

export function total() {
  return 0;
}
