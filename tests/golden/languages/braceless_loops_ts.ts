export function pairs(items: number[], count: number): number[][] {
  let o: number;
  const out: number[][] = [];
  for (const t of items) for (o = 0; o < count; ++o) out[out.length] = [t, o];
  return out;
}
