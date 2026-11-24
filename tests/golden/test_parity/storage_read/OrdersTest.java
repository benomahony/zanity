import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

class OrdersTest {
    JdbcTemplate jdbc;
    Orders orders;

    @Test
    void savesOrder() {
        orders.save(1);
        Integer id = jdbc.queryForObject("SELECT id FROM orders", Integer.class);
        assertEquals(1, id, "expected the saved order");
    }

    @Test
    void findsOrder() {
        orders.save(1);
        assertEquals(1, orders.find(1), "expected the saved order");
    }
}
