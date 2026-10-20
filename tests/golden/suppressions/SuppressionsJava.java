import java.util.List;

@SuppressWarnings("unchecked")
class SuppressionsJava {
  @java.lang.SuppressWarnings({"rawtypes"})
  List raw() {
    return null; // NOPMD
  }

  @Override
  public String toString() {
    return "x"; // NOSONAR
  }

  @Deprecated
  void honest() {}
}
