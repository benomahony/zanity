
export function ship(orders) {
  for (const order of orders) {
    order.ship();
  }
}

export function totals(orders) {
  let out = 0;
  for (const order of orders) {
    out += order.customer.balance;
  }
  return out;
}
