function narrow(flag: boolean): number {
  const onlyInside = 3;
  if (flag) {
    return onlyInside + 1;
  }
  return 0;
}

function created(flag: boolean): Date | null {
  const made = new Date(0);
  if (flag) {
    return made;
  }
  return null;
}

function reassigned(flag: boolean): number {
  let base = 1;
  const derived = base + 1;
  base = 5;
  if (flag) {
    return derived + base;
  }
  return base;
}
