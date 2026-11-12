export async function first() {
  const { second } = await import("./late.js");
  return second();
}
