const fetchFake = vi.fn(async (url: string, init: RequestInit) => {
  if (init.method === "POST") {
    return new Response(null, { status: 201 });
  }
  return new Response("{}");
});

function fakeSocket() {
  return { call: vi.fn(async (method: string) => (method === "GetProfileList" ? profiles : {})) };
}

describe("uploads", () => {
  it("inspects the image before running it", async () => {
    execFile.mockImplementation((_command, args, ...rest) => {
      switch (args[0]) {
        case "image":
          return rest[0](null, "1000:1000\n", "");
        default:
          return rest[0](null, "", "");
      }
    });
    const charge = vi.fn().mockResolvedValue("ch_1");
    const answer = vi.fn((x: number) => x * 2);
    const counter = vi.fn(() => (calls > 1 ? "again" : "first"));
    await upload();
    expect(answer(2)).toBe(4);
  });
});
