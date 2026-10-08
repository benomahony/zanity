import requests

requests.get("http://example.invalid/data")
requests.get("http://127.0.0.1:8080/health")
requests.get("http://[::1]:8080/health")
requests.get("https://example.invalid/data")
