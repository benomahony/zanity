class Repeats {
    int total(Order order) {
        int sum = order.lines.size();
        if (order.lines.size() > 10) sum += order.lines.size();
        return sum;
    }
}
