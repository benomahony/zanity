package main

func doubled(values []int) []int {
	var out []int
	for _, value := range values {
		out = append(out, value*2)
	}
	return out
}

func sizedDoubled(values []int) []int {
	out := make([]int, 0, len(values))
	for _, value := range values {
		out = append(out, value*2)
	}
	return out
}
