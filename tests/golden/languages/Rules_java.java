import java.util.List;
import org.junit.jupiter.api.Test;

class Rules {
    int countdown(int n) {
        assert n >= 0 : "n must not be negative";
        assert n < 100 : "n must be small";
        return countdown(n - 1);
    }

    void spin() {
        while (true) {}
        for (;;) {}
    }

    void bounded(List<Integer> items) {
        for (int item : items) {
            System.out.println(item);
        }
        for (int i = 0; i < items.size(); i++) {}
    }

    int many(int a, int b, int c, int d, int e) {
        return a + b + c + d + e;
    }

    int forward(int x) {
        return target(x);
    }

    void ignore() {
        try {
            work();
        } catch (Exception e) {}
    }

    void checks(List<Integer> items) {
        int ready = 5;
        assert ready == 5;
        assert items.remove(0) > 0 : "removes while checking";
    }

    @Test
    void waits() throws Exception {
        Thread.sleep(1000);
        double roll = Math.random();
        Object fake = mock(Object.class);
    }
}
