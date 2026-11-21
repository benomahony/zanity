package invoices

func InvoiceTotal(items []int, rate int) int {
	total := 0
	for _, item := range items {
		if item > 10 {
			total += item * rate
		} else {
			total += item
		}
	}
	return total
}
