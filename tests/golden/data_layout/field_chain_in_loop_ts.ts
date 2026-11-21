interface Row {
  balance: number;
  customer: { balance: number };
}

export function totals(rows: Row[]): number {
  let out = 0;
  for (const row of rows) {
    out += row.customer.balance;
  }
  return out;
}

export function direct(rows: Row[]): number {
  let out = 0;
  for (const row of rows) {
    out += row.balance;
  }
  return out;
}
