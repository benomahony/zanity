import java.nio.charset.StandardCharsets;

class SignerJava {
  byte[] sign(String message) {
    byte[] bytes = message.getBytes(StandardCharsets.UTF_8);
    return sign(bytes);
  }

  byte[] sign(byte[] data) {
    return data;
  }

  void log(String text) {
    log(new Entry(text));
  }

  void log(Entry entry) {
    store(entry);
  }

  int parse(String text) {
    return parse(42);
  }

  int parse(int value) {
    return value;
  }

  void mark(String label) {
    var entry = new Entry(label);
    mark(entry);
  }

  void mark(Entry entry) {
    store(entry);
  }

  int fact(int n) {
    int next = n - 1;
    return n == 0 ? 1 : n * fact(next);
  }

  int fact(String n) {
    return fact(Integer.parseInt(n));
  }

  void store(Object value) {}
}

class Entry {
  Entry(String text) {}
}
