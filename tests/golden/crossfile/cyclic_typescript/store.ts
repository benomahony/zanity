import { legacy } from "./legacy";

export function load(): number {
  return 1;
}

export function reload(): number {
  return legacy();
}
