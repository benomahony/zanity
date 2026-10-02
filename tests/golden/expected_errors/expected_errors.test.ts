it("rejects negative amounts", () => {
  expect(() => withdraw(-1)).toThrow();
  expect(() => withdraw(-2)).toThrow(Error);
  expect(() => withdraw(-3)).toThrow(RangeError);
  expect(() => withdraw(-4)).toThrow("negative amount");
});
