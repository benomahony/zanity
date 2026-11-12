export async function first(): Promise<number> {
  const { second } = await import("./late.js");
  return second();
}
