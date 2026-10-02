it("sends the receipt", () => {
  const send = jest.fn();
  checkout(send);
  expect(send).toHaveBeenCalledWith("receipt");
  expect(send).toHaveBeenCalledTimes(1);
  expect(total([1, 2])).toBe(3);
});
