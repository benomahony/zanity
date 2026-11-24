package parity

import "net/http"

func fetch() {
	http.Get("http://user:password@example.invalid/data")
	http.Get("https://example.invalid/login?api_token=visible")
	http.Get("https://example.invalid/data")
}
