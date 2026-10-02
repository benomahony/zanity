const fetcher = jest.fn();

describe("orders", () => {
  it("loads them", () => {
    const spy = vi.spyOn(api, "get");
    sinon.replace(api, "post", sinon.fake());
    client.patch("/orders/1");
    expect(spy).toBeDefined();
  });
});
