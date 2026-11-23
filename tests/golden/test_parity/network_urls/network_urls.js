function load() {
  fetch("http://user:password@example.invalid/data");
  fetch("https://example.invalid/login?api_token=visible");
  fetch("https://example.invalid/data");
}

module.exports = { load };
