function divide(value: number, divisor: number): number {
  const bad = value / 0;
  const good = value / divisor;
  const nearZero = value / 0.1;
  return bad + good + nearZero;
}
