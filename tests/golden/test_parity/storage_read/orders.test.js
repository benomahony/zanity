test("saves an order", async () => {
  await orders.save({ id: 1 });
  const row = await prisma.order.findFirst({ where: { id: 1 } });
  expect(row.id).toBe(1);
});

test("finds an order", async () => {
  await orders.save({ id: 1 });
  expect(await orders.find(1)).toEqual({ id: 1 });
});
