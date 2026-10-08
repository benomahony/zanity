function leave(url: string) {
  return window.open(url, "_blank");
}

function leaveSafely(url: string) {
  return window.open(url, "_blank", "noopener,noreferrer");
}

function sameTab(url: string) {
  return window.open(url, "_self");
}

function fixed() {
  return window.open("/help", "_blank");
}

function configured(url: string, features: string) {
  return window.open(url, "_blank", features);
}
