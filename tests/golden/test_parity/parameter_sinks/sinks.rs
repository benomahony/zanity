use axum::response::Redirect;

pub fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap()
}

pub fn read_fixed() -> String {
    std::fs::read_to_string("/etc/orders.conf").unwrap()
}

pub fn back(target: &str) -> Redirect {
    Redirect::to(target)
}

pub fn home() -> Redirect {
    Redirect::to("/")
}

pub fn select(document: &sxd_document::dom::Document, query: &str) {
    sxd_xpath::evaluate_xpath(document, query).unwrap();
    sxd_xpath::evaluate_xpath(document, "/orders/order").unwrap();
}
