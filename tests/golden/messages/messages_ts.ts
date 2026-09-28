function check(size: number): void {
  if (size < 0) throw new Error("Something went wrong");
  if (size > 10) throw new Error("ERR_TOO_BIG");
  console.error("");
  throw new Error("size must be between 0 and 10; lower --size");
}
