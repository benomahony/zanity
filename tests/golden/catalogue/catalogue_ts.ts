function flagged(x: number, items: number[]): number {
  if (x) {}
  for (const _ of items) {}
  if (false) { x = 1; }
  const y = true ? 1 : 2;
  x == 1.5;
  const apiKey = "sk-live-123";
  debugger;
  switch (x) {
    case 1:
      return 1;
      x = 3;
    default:
      break;
  }
  return y;
  x = 2;
}

function quiet(x: number): number {
  if (x) { /* nothing to do until the cache is warm */ }
  const same = x == 1.5;
  const tokenEnv = "API_TOKEN";
  return same ? 1 : helper();
  function helper(): number { return 2; }
}
