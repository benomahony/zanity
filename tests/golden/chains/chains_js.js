function ship(order) {
    const city = order.customer.address.city;
    const name = order.customer.name;
    return city + name + Math.PI.toFixed(2);
}
