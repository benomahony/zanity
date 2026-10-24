#[test]
fn rejects_constant_checks() {
    assert!(true); // parity: constant
    assert_eq!(2, 1 + 1); // parity: constant
    assert_eq!("abc", "abc"); // parity: constant
    let actual = calculate();
    assert_eq!(2, actual);
    assert_eq!(actual, 2);
    assert!(calculate() == 2);
    if unexpected() { assert!(false); }
    assert_eq!(format!("{}", actual), "2");
}
fn helper() { assert_eq!(2, 2); }
