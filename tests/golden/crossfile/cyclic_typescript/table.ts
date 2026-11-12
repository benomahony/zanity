import { columns } from "./model";

export interface Row {
  cells: string[];
}

export function width(): number {
  return columns;
}
