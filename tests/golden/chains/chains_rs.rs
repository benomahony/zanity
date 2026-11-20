fn ship(order: &Order) -> String {
    let city = order.customer.address.city.clone();
    let name = order.customer.name.len();
    format!("{city}{name}")
}

struct Collector { def_collector: Def }

impl Collector {
    fn note(&mut self, id: u32) {
        self.def_collector
            .def_map
            .diagnostics
            .push(id);
    }
}
