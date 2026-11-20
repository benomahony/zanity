package main

type Order struct{ Customer struct{ Balance int } }

func (o *Order) Ship() {}

func ship(orders []*Order) {
	for _, order := range orders {
		order.Ship()
	}
}

func totals(orders []Order) int {
	out := 0
	for _, order := range orders {
		out += order.Customer.Balance
	}
	return out
}
