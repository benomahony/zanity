async function fetchUrl(url: string) {
  return fetch(url);
}

async function fetchHealth(url: string) {
  return fetch("https://health.example.invalid");
}
