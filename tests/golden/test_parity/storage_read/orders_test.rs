#[tokio::test]
async fn saves_order() {
    let pool = pool().await;
    save(&pool, 1).await;
    let row: (i64,) = sqlx::query_as("SELECT id FROM orders").fetch_one(&pool).await.unwrap();
    assert_eq!(row.0, 1, "expected the saved order");
}

#[tokio::test]
async fn finds_order() {
    let pool = pool().await;
    save(&pool, 1).await;
    assert_eq!(find(&pool, 1).await, Some(1), "expected the saved order");
}
