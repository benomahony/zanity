function trust(fragment) {
    return unsafeHTML(fragment);
}
function fixed(fragment) {
    return unsafeHTML("<strong>Ready</strong>");
}
function escaped(fragment) {
    const checked = escapeHtml(fragment);
    return unsafeHTML(checked);
}
