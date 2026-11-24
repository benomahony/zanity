use tracing::instrument;

pub async fn refund() -> &'static str {
    "refunded"
}

#[instrument]
pub async fn charge() -> &'static str {
    "charged"
}
