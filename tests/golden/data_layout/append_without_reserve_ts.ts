export function doubled(values: number[]): number[] {
  const out: number[] = [];
  for (const value of values) {
    out.push(value * 2);
  }
  return out;
}
