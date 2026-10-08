use regex::Regex;

fn patterns() {
    let _dangerous = Regex::new(r"([a-z]+)+$");
    let _safe = Regex::new(r"(?:ab+)+$");
}
