import * as journal from "./journal.js";

export function post(entry) {
  return journal.record(entry) + journal.total();
}
