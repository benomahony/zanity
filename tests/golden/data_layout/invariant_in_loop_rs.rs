fn count(lines: &[String], word: &str) -> usize {
    let mut found = 0;
    for line in lines {
        if line.contains(&word.to_lowercase()) {
            found += 1;
        }
    }
    found
}

fn each(lines: &[String]) -> usize {
    let mut found = 0;
    for line in lines {
        found += line.trim().len();
    }
    found
}
