import java.util.Map;
import java.util.function.BiFunction;

class Billing {
  long total(Map<String, Integer> usage) {
    BiFunction<String, Map<String, Integer>, Long> cost = Costs::flat;
    return cost.apply("gpt", usage) + Costs.unused("gpt", usage);
  }
}
