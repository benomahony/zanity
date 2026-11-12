import { rate } from "./index.js";

export function levy(amount) {
  return amount * rate;
}
