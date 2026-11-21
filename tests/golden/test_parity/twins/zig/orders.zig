pub fn orderTotal(items: []const u32, rate: u32) u32 {
    var total: u32 = 0;
    for (items) |item| {
        if (item > 10) {
            total += item * rate;
        } else {
            total += item;
        }
    }
    return total;
}
