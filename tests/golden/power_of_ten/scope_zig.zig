fn narrow(flag: bool) u32 {
    const only_inside = 3;
    if (flag) {
        return only_inside + 1;
    }
    return 0;
}

fn direct(flag: bool) u32 {
    const value = 3;
    if (flag) return value;
    return value + 1;
}

fn split(flag: bool) u32 {
    const both = 3;
    if (flag) {
        return both;
    } else {
        return both + 1;
    }
}

fn looped(items: []const u32) void {
    var seen: u32 = 0;
    for (items) |item| {
        seen += item;
    }
}

fn condition(n: u32) u32 {
    const limit = 10;
    if (n > limit) {
        return 1;
    }
    return 0;
}

fn nested(items: []const u32) u32 {
    var sum: u32 = 0;
    for (items) |item| {
        const doubled = item * 2;
        if (item > 1) {
            sum += doubled;
        }
    }
    return sum;
}
