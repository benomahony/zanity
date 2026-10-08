function leave(url) {
  return window.open(url, "_blank", "width=800");
}

function leaveSafely(url) {
  return window.open(url, "_blank", "noopener");
}

function unrelated(windowFactory, url) {
  return windowFactory.open(url, "_blank");
}
