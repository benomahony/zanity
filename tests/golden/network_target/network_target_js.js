async function fetchUrl(url) {
    return fetch(url);
}
async function fetchHealth(url) {
    return fetch("https://health.example.invalid");
}
