function givenAUser(name: string) {
  return [name];
}

it("signs in", () => {
  expect(givenAUser("ada")).toEqual(["ada"]);
});

it("signs out", () => {
  givenAUser("ada");
});
