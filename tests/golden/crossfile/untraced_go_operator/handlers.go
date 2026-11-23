package main

import "net/http"

func refund(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func charge(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "charge")
	defer span.End()
	w.Write([]byte(ctx.Err().Error()))
}

func fetch(client *http.Client) error {
	response, err := client.Get("https://example.com/orders")
	if err != nil {
		return err
	}
	return response.Body.Close()
}
