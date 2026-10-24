#[test]
fn reaches_real_resources() {
    std::thread::sleep(delay); // parity: sleep-in-test
    while ready() { // parity: polling-loop
        std::thread::sleep(delay); // parity: sleep-in-test
    }
    rand::random(); // parity: nondeterministic-test
    std::fs::read_to_string("config"); // parity: filesystem-in-test
    reqwest::blocking::get("https://example.com"); // parity: network-in-test
    std::process::Command::new("ls"); // parity: process-in-test
    std::io::stdin(); // parity: stdin-in-test
}
fn helper() { std::thread::sleep(delay); std::fs::read_to_string("config"); }
