import type { Canvas } from "./canvas";

export function area(canvas: Canvas): number {
  return canvas.width * canvas.height;
}
