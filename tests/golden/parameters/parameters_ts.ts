function total(prices: number[], currency: string): number {
  let sum = 0;
  for (const p of prices) sum += p;
  return sum;
}

function format(value: number, _locale: string): string {
  const text = value.toFixed(2);
  return text;
}

class Cache {
  constructor(private ttl: number, readonly size: number, label: string) {
    this.start();
    this.warm();
  }
}

function run(logger: { info: (msg: string) => void }, steps: number): void {
  logger.info("start");
  logger.info(`steps: ${steps}`);
}
