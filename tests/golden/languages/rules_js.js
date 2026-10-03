import assert from "node:assert";

function countdown(n) {
  assert(n >= 0, "n must not be negative");
  assert(n < 100, "n must be small");
  return countdown(n - 1);
}

const spin = () => {
  while (true) {}
  for (;;) {}
};

function bounded(items) {
  for (const item of items) {
    console.log(item);
  }
  for (let i = 0; i < items.length; i++) {}
}

function many(a, b, c, d, e) {
  return a + b + c + d + e;
}

const forward = (x) => target(x);

function ignore() {
  try {
    work();
  } catch (error) {}
}

function checks(items) {
  const ready = true;
  assert(ready);
  assert(items.pop() !== undefined, "pops while checking");
}

it("waits", async () => {
  await sleep(1000);
  const roll = Math.random();
  const fake = jest.fn();
});
