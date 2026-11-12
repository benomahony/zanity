import { area } from "./shape";

export interface Canvas {
  width: number;
  height: number;
}

export function fill(canvas: Canvas): number {
  return area(canvas);
}
