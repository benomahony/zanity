fn check(size: i64, path: Option<&str>) {
    if size < 0 {
        panic!("invalid argument");
    }
    let p = path.expect("E_NO_PATH");
    if size > 10 {
        panic!("size {} is over 10; lower --size", size);
    }
}
