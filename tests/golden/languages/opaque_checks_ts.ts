test("total includes tax", () => {
  expect(total() === 110).toBe(true);
});

test("receipt lists tax", () => {
  expect(receipt().includes("tax")).toBeTruthy();
});

test("total is not zero", () => {
  expect(total() === 0).toBe(false);
});

test("total is loosely equal", () => {
  expect(total() == 110).toBe(true);
});

test("total reads plainly", () => {
  expect(total()).toBe(110);
});
