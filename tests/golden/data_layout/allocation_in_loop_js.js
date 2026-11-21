export function parse(lines) {
  const out = [];
  for (const line of lines) {
    out.push(structuredClone(line));
  }
  return out;
}
