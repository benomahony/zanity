fn doubled(values: &[u32]) -> Vec<u32> {
    let mut out = Vec::new();
    for value in values {
        out.push(value * 2);
    }
    out
}

fn sized_doubled(values: &[u32]) -> Vec<u32> {
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        out.push(value * 2);
    }
    out
}
