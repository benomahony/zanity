const std = @import("std");

const api_token = "tok-123";
const token_env = "API_TOKEN";

fn flagged(x: f64, xs: []const u8) f64 {
    if (x > 0) {}
    for (xs) |_| {}
    if (true) {
        g();
    }
    while (false) {
        g();
    }
    if (x > 2) {
        g();
    } else {}
    if (x == 1.5) {
        g();
    }
    @breakpoint();
    return x;
}

fn quiet(x: f64) f64 {
    if (x > 0) {
        // nothing to do until the cache is warm
    }
    if (x == 0.0) {
        g();
    }
    return x;
}

fn g() void {}
