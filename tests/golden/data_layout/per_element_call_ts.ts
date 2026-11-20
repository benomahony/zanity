interface Order {
  ship(): void;
  customer: { balance: number };
}

export function ship(orders: Order[]): void {
  for (const order of orders) {
    order.ship();
  }
}

export function totals(orders: Order[]): number {
  let out = 0;
  for (const order of orders) {
    out += order.customer.balance;
  }
  return out;
}
