const API_TOKEN: &str = "tok-123";
const TOKEN_ENV: &str = "API_TOKEN";

fn flagged(mut x: f64) -> f64 {
    if x > 0.0 {}
    if true {
        x = 1.0;
    }
    while false {
        x = 2.0;
    }
    x == 1.5;
    let secret = "s3cr3t";
    dbg!(x);
    return x;
    x = 3.0;
}

fn quiet(mut x: f64) -> f64 {
    if x > 0.0 {
        // nothing to do until the cache is warm
    }
    if x == 0.0 {
        x = 1.0;
    }
    let same = x == 1.5;
    if same { 1.0 } else { x }
}
