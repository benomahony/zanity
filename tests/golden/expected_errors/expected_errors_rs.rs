#[test]
#[should_panic]
fn rejects_negative_amounts() {
    withdraw(-1);
}

#[test]
#[should_panic(expected = "negative amount")]
fn rejects_negative_amounts_with_a_reason() {
    withdraw(-1);
}
