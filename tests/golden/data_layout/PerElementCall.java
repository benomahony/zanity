import java.util.List;

class PerElementCall {
    static void ship(List<Order> orders) {
        for (Order order : orders) {
            order.ship();
        }
    }

    static long totals(List<Order> orders) {
        long out = 0;
        for (Order order : orders) {
            out += order.customer.balance;
        }
        return out;
    }
}
