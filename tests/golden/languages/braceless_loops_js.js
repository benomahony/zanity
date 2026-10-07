export function pairs(items, count) {
  let o;
  const out = [];
  for (const t of items) for (o = 0; o < count; ++o) out[out.length] = [t, o];
  return out;
}
