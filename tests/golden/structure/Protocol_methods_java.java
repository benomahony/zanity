class Session {
  int forward(int x) {
    return target(x);
  }

  public String toString() {
    return render();
  }

  public int hashCode() {
    return Objects.hash(a, b);
  }
}
