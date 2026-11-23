pub async fn load() {
    let _ = reqwest::get("http://user:password@example.invalid/data").await;
    let _ = reqwest::get("https://example.invalid/login?api_token=visible").await;
    let _ = reqwest::get("https://example.invalid/data").await;
}
