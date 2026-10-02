#[test]
fn reads_the_name() {
    let mut name = String::new();
    std::io::stdin().read_line(&mut name).unwrap();
}
