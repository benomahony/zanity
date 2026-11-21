export function totals(rows) {
  let out = 0;
  for (const row of rows) {
    out += row.customer.balance;
  }
  return out;
}

export function direct(rows) {
  let out = 0;
  for (const row of rows) {
    out += row.balance;
  }
  return out;
}
