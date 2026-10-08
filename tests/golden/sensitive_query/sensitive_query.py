import requests

requests.get("https://example.invalid/login?api_token=visible")
requests.get("https://example.invalid/search?q=public")
requests.get("https://example.invalid/login", headers={"Authorization": "Bearer value"})
