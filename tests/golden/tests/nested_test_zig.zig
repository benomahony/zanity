test "deep" {
    var n: u32 = 0;
    for (0..3) |a| {
        if (a > 0) {
            for (0..3) |b| {
                if (b > 0) {
                    if (a > b) n += 1;
                }
            }
        }
    }
}

test "flat" {
    var n: u32 = 0;
    for (0..3) |a| {
        if (a > 0) n += 1;
    }
}
