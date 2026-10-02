fn total(items: []const u32) u32 {
    var sum: u32 = items.len * 2;
    if (items.len * 2 > 100) sum += items.len * 2;
    return sum;
}
