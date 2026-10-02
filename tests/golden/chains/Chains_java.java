class Chains {
    String ship(Order order) {
        String city = order.customer.address.city;
        String name = order.customer.name;
        return city + name;
    }
}
