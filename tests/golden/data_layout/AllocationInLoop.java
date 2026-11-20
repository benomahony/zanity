import java.util.List;

class AllocationInLoop {
    static int total(List<int[]> rows) {
        int sum = 0;
        for (int[] row : rows) {
            int[] copy = row.clone();
            sum += copy.length;
        }
        return sum;
    }

    static String label(int value) {
        return String.format("%d", value);
    }
}
