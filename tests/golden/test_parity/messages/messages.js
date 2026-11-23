// FIXME: this accepts expired credentials.
function compare(a, b) {
  assert(a > b, "expected a > b");
  if (a > 10) throw new Error("invalid input");
  if (b > 10) throw new Error("ERR_TOO_BIG");
  if (a < 0) throw new Error(`a must not be negative, since it counts retries, got ${a}`);
  return a - b;
}
module.exports = { compare };
