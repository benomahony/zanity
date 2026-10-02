package parameters

func Total(prices []int, currency string) int {
	sum := 0
	for _, p := range prices {
		sum += p
	}
	return sum
}

func Handler(w Writer, _ *Request) {
	w.Write([]byte("ok"))
	w.Flush()
}

func (c *Cache) Get(key string) string {
	value := lookup(key)
	return value
}
