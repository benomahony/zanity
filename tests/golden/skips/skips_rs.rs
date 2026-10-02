#[test]
#[ignore]
fn off() {}

#[test]
#[ignore = "slow"]
fn off_with_reason() {}

#[test]
fn on() {}
