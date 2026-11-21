use axum::{routing::get, Router};
use tracing::{info_span, instrument};

mod handlers;

#[get("/orders/{id}")]
async fn order() -> String {
    String::from("order")
}

#[instrument]
#[post("/orders")]
async fn create() -> String {
    String::from("created")
}

#[get("/health")]
async fn health() -> String {
    let _span = info_span!("health").entered();
    String::from("ok")
}

fn router() -> Router {
    Router::new()
        .route("/refunds", get(handlers::refund))
        .route("/charges", get(handlers::charge))
        .route("/inline", get(|| async { "inline" }))
}
