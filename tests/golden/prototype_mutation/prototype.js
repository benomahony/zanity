function mutate(target, value) {
  target.__proto__ = value;
  const inherited = target.__proto__;
  target.safe = value;
  return inherited;
}
