import requests


def fetch(url):
    return requests.get(url)


def fetch_health(url):
    return requests.get("https://health.example.invalid")
