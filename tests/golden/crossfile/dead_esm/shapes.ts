import { round } from "./numbers";

function square(side: number): number {
  return side * side;
}

function oldArea(side: number): number {
  return square(side);
}

function circle(radius: number): number {
  return round(3.14159 * radius * radius);
}

export function area(radius: number): number {
  return circle(radius);
}
