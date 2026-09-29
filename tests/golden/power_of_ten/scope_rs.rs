fn narrow(flag: bool) -> i32 {
    let only_inside = 3;
    if flag {
        return only_inside + 1;
    }
    0
}

fn direct(flag: bool) -> i32 {
    let value = 3;
    if flag {
        return value;
    }
    value + 1
}

fn looped(items: &[i32]) {
    let mut seen = 0;
    for item in items {
        seen += item;
    }
}

fn closure() -> impl Fn() -> i32 {
    let captured = 3;
    move || captured
}

fn nested(items: &[i32]) -> i32 {
    let mut sum = 0;
    for item in items {
        let doubled = item * 2;
        if *item > 1 {
            sum += doubled;
        }
    }
    sum
}
