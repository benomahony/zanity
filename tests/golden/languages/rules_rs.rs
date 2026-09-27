use std::thread;
use std::time::Duration;

fn countdown(n: u32) -> u32 {
    assert!(n < 100, "n must be small");
    debug_assert!(n != 7, "n must not be seven");
    countdown(n - 1)
}

fn spin() {
    loop {}
}

fn bounded(items: &[u32]) {
    for item in items {
        println!("{}", item);
    }
    while true {}
}

fn many(a: u32, b: u32, c: u32, d: u32, e: u32) -> u32 {
    a + b + c + d + e
}

fn forward(x: u32) -> u32 {
    target(x)
}

fn ignore() {
    let _ = work();
    match work() {
        Ok(_) => {}
        Err(_) => {}
    }
}

fn unexplained(n: u32) {
    assert!(n > 0);
    assert!(n < 10);
}

#[test]
fn waits() {
    thread::sleep(Duration::from_secs(1));
    let roll: u8 = rand::random();
}
