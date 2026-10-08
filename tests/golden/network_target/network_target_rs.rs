async fn fetch(url: &str) {
    let _ = reqwest::get(url).await;
}

async fn fetch_health(url: &str) {
    let _ = reqwest::get("https://health.example.invalid").await;
}
