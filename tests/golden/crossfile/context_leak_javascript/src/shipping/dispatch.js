import { postEntry } from "../billing/ledger.js";

export function dispatch(cost) {
  return postEntry(cost);
}
