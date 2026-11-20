package main

import "fmt"

func labels(values []int) []string {
	out := make([]string, 0, len(values))
	for _, value := range values {
		out = append(out, fmt.Sprintf("%d", value))
	}
	return out
}

func buffers(count int) [][]byte {
	out := make([][]byte, count)
	for i := 0; i < count; i++ {
		out[i] = make([]byte, 64)
	}
	return out
}
