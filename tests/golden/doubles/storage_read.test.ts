it("creates a diagram", async () => {
  await run(["diagram", "create", "flow"]);
  const rows = await db().query.diagrams.findMany();
  const one = await testDb.query.videos.findFirst({ where: eq(videos.id, "v1") });
  const before = await testDb.select().from(schema.clips);
  const hits = await testDb.execute(sql`SELECT id FROM ${diagrams} WHERE search_vector @@ q`);
  await testDb.execute(sql`INSERT INTO ${jobEvents} (job_id) VALUES (${id})`);
  const built = await testDb.select().where(eq(clips.id, "c1"));
  expect(rows).toHaveLength(1);
  expect(await diagrams.list()).toEqual([one, before, hits, built]);
});

function seedRows() {
  return testDb.query.videos.findMany();
}
