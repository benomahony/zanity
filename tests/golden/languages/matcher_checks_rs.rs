#[test]
fn total_includes_tax() {
    assert_that!(total(), equal_to(110));
}

#[test]
fn total_is_ok() {
    assert_matches!(total(), Ok(_));
}

#[test]
fn total_prints_receipt() {
    println!("{}", total());
}
