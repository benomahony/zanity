import java.util.ArrayList;
import java.util.List;

class AppendWithoutReserve {
    static List<Integer> doubled(List<Integer> values) {
        List<Integer> out = new ArrayList<>();
        for (int value : values) {
            out.add(value * 2);
        }
        return out;
    }

    static List<Integer> sizedDoubled(List<Integer> values) {
        List<Integer> out = new ArrayList<>(values.size());
        for (int value : values) {
            out.add(value * 2);
        }
        return out;
    }
}
