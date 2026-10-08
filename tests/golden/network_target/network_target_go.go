package main

import "net/http"

func fetch(url string) {
	_, _ = http.Get(url)
}

func fetchHealth(url string) {
	_, _ = http.Get("https://health.example.invalid")
}
