class Messages {
  void check(int size) {
    if (size < 0) throw new IllegalArgumentException("Invalid input");
    if (size > 10) throw new IllegalStateException("ERR_TOO_BIG");
    throw new IllegalStateException("size must be between 0 and 10; lower --size");
  }
}
