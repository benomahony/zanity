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

func received(flag bool, ch chan int) int {
	value := <-ch
	if flag {
		return value
	}
	return 0
}
