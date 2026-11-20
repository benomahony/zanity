import { postEntry } from "../billing/index.js";
import type { Entry } from "../billing/ledger.js";

export function route(entry: Entry, cost: number): number {
  return postEntry(cost);
}
