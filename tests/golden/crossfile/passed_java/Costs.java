import java.util.Map;

class Costs {
  static long flat(String model, Map<String, Integer> usage) {
    return usage.size();
  }

  static long unused(String model, Map<String, Integer> usage) {
    return usage.size();
  }
}
