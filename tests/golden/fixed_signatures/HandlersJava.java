interface Scorer {
  int score(int a, int b);

  default int bonus(int a, int b) {
    return 0;
  }
}

class Impl implements Scorer {
  public int score(int a, int b) {
    int x = a + 1;
    return x * 2;
  }

  int own(int a, int b) {
    int x = a + 1;
    return x * 2;
  }

  Scorer anonymous() {
    return new Scorer() {
      int score(int a, int b) {
        int x = a + 1;
        return x * 2;
      }
    };
  }
}
