package chains

func Ship(order Order) string {
	city := order.Customer.Address.City
	name := order.Customer.Name
	return city + name
}
