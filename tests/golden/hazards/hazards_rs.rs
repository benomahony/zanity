use std::time::{Instant, SystemTime};

fn flagged(x: i32) {
    x;
    let _c = reqwest::Client::builder().danger_accept_invalid_certs(true);
    let _d = SystemTime::now() - x;
    md5::compute(b"x");
}

fn quiet(x: i32) {
    let _y = x;
    let _c = reqwest::Client::builder().danger_accept_invalid_certs(false);
    let _d = Instant::now();
}
