import { postEntry } from "../billing/index.js";

export function route(cost) {
  return postEntry(cost);
}
