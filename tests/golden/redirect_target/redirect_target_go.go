package main

import "net/http"

func leave(w http.ResponseWriter, r *http.Request, next string) {
	http.Redirect(w, r, next, http.StatusFound)
}

func home(w http.ResponseWriter, r *http.Request, next string) {
	http.Redirect(w, r, "/home", http.StatusFound)
}
