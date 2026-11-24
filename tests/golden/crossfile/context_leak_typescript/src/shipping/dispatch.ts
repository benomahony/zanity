import { postEntry } from "../billing/ledger.js";

export function dispatch(cost: number): number {
  return postEntry(cost);
}
