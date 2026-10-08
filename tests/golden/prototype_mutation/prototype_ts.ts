function mutate(target: Record<string, unknown>, value: object): void {
  target["__proto__"] = value;
  target["safe"] = value;
}
