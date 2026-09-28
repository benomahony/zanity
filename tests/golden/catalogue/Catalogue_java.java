class Catalogue {
  static final String PASSWORD = "hunter2";
  static final String TOKEN_ENV = "API_TOKEN";

  double flagged(double x) {
    if (x > 0) {}
    if (true) { x = 1; }
    boolean same = x == 1.5;
    try { run(); } catch (Exception e) { log(e); }
    try { run(); } catch (Throwable t) { log(t); }
    if (x > 2) { run(); } else {}
    int y = false ? 1 : 2;
    return x;
  }

  double quiet(double x) {
    if (x > 0) { /* nothing to do until the cache is warm */ }
    if (x == 0.0) { x = 1; }
    try { run(); } catch (IllegalStateException e) { log(e); }
    return x;
  }

  void run() {}

  void log(Throwable t) {}
}
