export function labels(rows: number[][]): number[][] {
  const out: number[][] = [];
  for (const row of rows.slice(1)) {
    out.push(row.slice());
  }
  return out;
}

export function once(rows: number[]): number[] {
  return rows.slice(1);
}
