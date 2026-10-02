fn total(items: &[i32]) -> i32 {
    let sum: i32 = items.iter().sum();
    let max = items.iter().max().unwrap();
    let count = items.iter().count() as i32;
    sum + max + count
}
