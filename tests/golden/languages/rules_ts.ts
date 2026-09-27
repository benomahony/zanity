import assert from "node:assert";

function countdown(n: number): number {
  assert(n >= 0, "n must not be negative");
  assert(n < 100, "n must be small");
  return countdown(n - 1);
}

const spin = (): void => {
  while (true) {}
  for (;;) {}
};

function bounded(items: number[]): void {
  for (const item of items) {
    console.log(item);
  }
  for (let i = 0; i < items.length; i++) {}
}

function many(a: number, b: number, c: number, d: number, e: number): number {
  return a + b + c + d + e;
}

const forward = (x: number) => target(x);

function ignore(): void {
  try {
    work();
  } catch (error) {}
}

function checks(items: number[]): void {
  const ready = true;
  assert(ready);
  assert(items.pop() !== undefined, "pops while checking");
}

it("waits", async () => {
  await sleep(1000);
  const roll = Math.random();
  const fake = jest.fn();
});
