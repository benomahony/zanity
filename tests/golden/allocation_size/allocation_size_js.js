function reserve(size) {
    return Buffer.alloc(size);
}
function fixed(size) {
    return Buffer.alloc(4096);
}
function bounded(size) {
    const boundedSize = Math.min(size, 4096);
    return Buffer.alloc(boundedSize);
}
