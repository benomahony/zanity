class AllocationSize {
    ByteBuffer reserve(int size) {
        return ByteBuffer.allocate(size);
    }

    ByteBuffer fixed(int size) {
        return ByteBuffer.allocate(4096);
    }

    ByteBuffer bounded(int size) {
        int boundedSize = Math.min(size, 4096);
        return ByteBuffer.allocate(boundedSize);
    }
}
