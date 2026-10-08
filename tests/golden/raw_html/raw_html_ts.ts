function trust(fragment: string) {
  return unsafeHTML(fragment);
}

function fixed(fragment: string) {
  return unsafeHTML("<strong>Ready</strong>");
}

function escaped(fragment: string) {
  const checked = escapeHtml(fragment);
  return unsafeHTML(checked);
}
