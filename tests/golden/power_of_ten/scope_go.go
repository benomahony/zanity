package scope

func narrow(flag bool) int {
	onlyInside := 3
	if flag {
		return onlyInside + 1
	}
	return 0
}

func declared(flag bool) int {
	var total int
	if flag {
		total = 2
		return total
	}
	return 0
}

func direct(flag bool) int {
	value := 3
	if flag {
		return value
	}
	return value + 1
}

func looped(items []int) {
	seen := 0
	for _, item := range items {
		seen += item
	}
}

func closure() func() int {
	captured := 3
	return func() int { return captured }
}

func shadowed(flag bool) int {
	name := 3
	f := func(name int) int { return name }
	if flag {
		return name
	}
	return f(1)
}
