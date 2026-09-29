function narrow(flag: boolean): number {
  const onlyInside = 3;
  if (flag) {
    return onlyInside + 1;
  }
  return 0;
}

function direct(flag: boolean): number {
  const value = 3;
  if (flag) {
    return value;
  }
  return value + 1;
}

function looped(items: number[]): void {
  let seen = 0;
  for (const item of items) {
    seen += item;
  }
}

function closure(): () => number {
  const captured = 3;
  return () => captured;
}

function hoisted(flag: boolean): number {
  var old = 3;
  if (flag) {
    return old;
  }
  return 0;
}
