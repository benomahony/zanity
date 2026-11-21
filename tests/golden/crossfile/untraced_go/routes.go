package main

import (
	"net/http"

	"go.opentelemetry.io/otel"
)

var tracer = otel.Tracer("orders")

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/orders", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/traced", func(w http.ResponseWriter, r *http.Request) {
		ctx, span := tracer.Start(r.Context(), "traced")
		defer span.End()
		w.Write([]byte(ctx.Err().Error()))
	})
	mux.HandleFunc("/refunds", refund)
	mux.HandleFunc("/charges", charge)
	http.ListenAndServe(":8080", mux)
}
