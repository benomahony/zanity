fn trust(fragment: String) {
    axum::response::Html(fragment);
}

fn fixed(fragment: String) {
    axum::response::Html("<strong>Ready</strong>");
}

fn escaped(fragment: String) {
    let checked = html_escape::encode_text(&fragment);
    axum::response::Html(checked);
}
