package extract

import "fmt"

func Report(orders []Order, rate float64) float64 {
	paid := 0
	total := 0.0
	for _, o := range orders {
		if o.Paid {
			paid++
			total += o.Amount * rate
		}
	}
	fmt.Println("Report")
	fmt.Println("======")
	fmt.Println("paid:", paid)
	fmt.Println("orders:", len(orders))
	fmt.Println("total:", total)
	ratio := float64(paid) / float64(len(orders)+1)
	fmt.Println("ratio:", ratio)
	notes := []string{}
	if total > 1000 {
		notes = append(notes, "large")
	}
	if paid < len(orders) {
		notes = append(notes, "chase unpaid")
	}
	fmt.Println(notes)
	fmt.Println("done")
	fmt.Println("rate:", rate)
	fmt.Println("end")
	fmt.Println("line 0")
	fmt.Println("line 1")
	fmt.Println("line 2")
	fmt.Println("line 3")
	fmt.Println("line 4")
	fmt.Println("line 5")
	fmt.Println("line 6")
	fmt.Println("line 7")
	fmt.Println("line 8")
	fmt.Println("line 9")
	fmt.Println("line 10")
	fmt.Println("line 11")
	fmt.Println("line 12")
	fmt.Println("line 13")
	fmt.Println("line 14")
	fmt.Println("line 15")
	fmt.Println("line 16")
	fmt.Println("line 17")
	fmt.Println("line 18")
	fmt.Println("line 19")
	fmt.Println("line 20")
	fmt.Println("line 21")
	fmt.Println("line 22")
	fmt.Println("line 23")
	fmt.Println("line 24")
	fmt.Println("line 25")
	fmt.Println("line 26")
	fmt.Println("line 27")
	fmt.Println("line 28")
	fmt.Println("line 29")
	fmt.Println()
	return total
}
