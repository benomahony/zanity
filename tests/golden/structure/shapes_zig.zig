fn many(a: u32, b: u32, c: u32, d: u32, e: u32) u32 {
    return a + b + c + d + e;
}

fn four(a: u32, b: u32, c: u32, d: u32) u32 {
    return a + b + c + d;
}

fn forward(x: u32) u32 {
    return target(x);
}

fn forwardTry(x: u32) !u32 {
    return try target(x);
}

fn forwardCall(x: u32) void {
    target(x);
}

fn real(x: u32) u32 {
    const y = x + 1;
    return target(y);
}

fn handlers() void {
    risky() catch {};
    risky() catch |_| {};
    risky() catch |err| {
        log(err);
    };
}
