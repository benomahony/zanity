fn ship(order: &Order) -> String {
    let city = order.customer.address.city.clone();
    let name = order.customer.name.len();
    format!("{city}{name}")
}
