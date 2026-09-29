fn narrow(flag: bool) -> i32 {
    let only_inside = 3;
    if flag {
        return only_inside + 1;
    }
    0
}

fn called(flag: bool) -> i32 {
    let computed = compute();
    if flag {
        return computed;
    }
    0
}

fn formatted(flag: bool) -> String {
    let text = format!("{}", 3);
    if flag {
        return text;
    }
    String::new()
}
