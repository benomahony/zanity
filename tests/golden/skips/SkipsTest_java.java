import org.junit.jupiter.api.Disabled;
import org.junit.jupiter.api.Test;

class SkipsTest {
    @Disabled
    @Test
    void off() {}

    @Disabled("flaky")
    @Test
    void offWithReason() {}

    @Test
    void on() {}
}
