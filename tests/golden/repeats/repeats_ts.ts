function total(items: Item[], rate: number): number {
  let sum = 0;
  for (const item of items) {
    sum += item.price * rate;
    if (item.price * rate > 100) sum += (item.price * rate) / 10;
  }
  return sum;
}

function label(item: Item): string {
  const name = item.name;
  const upper = item.name.toUpperCase();
  return name + upper + item.name;
}
