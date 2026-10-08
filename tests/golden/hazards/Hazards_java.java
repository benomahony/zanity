class Hazards {
  int flagged(String s, int x) throws Exception {
    try { run(); } finally { return 1; }
    if (s == "a") {}
    if (!s.isEmpty() == true) {}
    switch (x) { case 1: run(); case 2: break; }
    long d = System.currentTimeMillis() - x;
    System.exit(1);
    thing.finalize();
    throw new Exception("boom");
  }

  int quiet(String s, int x) throws java.io.IOException {
    if (s.equals("a")) {}
    switch (x) { case 1: run(); break; case 2: break; default: break; }
    long d = System.nanoTime() - x;
    throw new IllegalStateException("x must be 1 or 2; got another value");
  }

  void run() {}
}
