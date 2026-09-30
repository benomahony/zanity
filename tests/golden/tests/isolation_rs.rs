#[test]
fn reaches_out() {
    std::env::set_var("MODE", "test");
    std::fs::read_to_string("config.json");
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("out.txt"), "ok");
    std::env::temp_dir();
    reqwest::blocking::get("https://example.com");
    rusqlite::Connection::open("app.db");
    rusqlite::Connection::open(":memory:");
    std::process::Command::new("ls");
}

fn helper() {
    std::env::set_var("MODE", "prod");
    std::process::Command::new("ls");
}
