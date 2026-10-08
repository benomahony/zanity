function inspect(value: unknown) {
  return util.isArray(value);
}

function inspectSupported(value: unknown) {
  return Array.isArray(value);
}

function unrelated(otherUtil: Utility, value: unknown) {
  return otherUtil.isArray(value);
}
