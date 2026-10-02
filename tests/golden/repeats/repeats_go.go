package repeats

func Total(items []map[string]int) int {
	sum := 0
	for _, item := range items {
		sum += item["price"]
		if item["price"] > 100 {
			sum += item["price"] / 10
		}
	}
	return sum
}
