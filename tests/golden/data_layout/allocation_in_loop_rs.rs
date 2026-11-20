fn names(values: &[u32]) -> Vec<String> {
    let mut out = Vec::new();
    for value in values {
        out.push(value.to_string());
    }
    out
}

fn copies(values: &Vec<u32>) -> u32 {
    let mut total = 0;
    for value in values.clone() {
        total += value;
    }
    total
}
