use axum::{routing::get, Router};
use tower_http::trace::TraceLayer;
use tracing::info_span;

async fn order() -> String {
    String::from("order")
}

async fn traced() -> String {
    let _span = info_span!("traced").entered();
    String::from("traced")
}

fn router() -> Router {
    Router::new()
        .route("/orders", get(order))
        .route("/traced", get(traced))
        .layer(TraceLayer::new_for_http())
}
