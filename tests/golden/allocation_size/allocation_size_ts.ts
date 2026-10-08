function reserve(size: number) {
  return Buffer.alloc(size);
}

function fixed(size: number) {
  return Buffer.alloc(4096);
}

function bounded(size: number) {
  const boundedSize = Math.min(size, 4096);
  return Buffer.alloc(boundedSize);
}
