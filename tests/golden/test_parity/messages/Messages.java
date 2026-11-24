class Messages {
    // FIXME: this accepts expired credentials.
    int compare(int a, int b) {
        assert a > b : "expected a > b";
        if (a > 10) throw new IllegalArgumentException("invalid input");
        if (b > 10) throw new IllegalStateException("ERR_TOO_BIG");
        if (a < 0) throw new IllegalArgumentException("a must not be negative, since it counts retries, got " + a);
        return a - b;
    }
}
