package variadics

func logAll(messages ...string) int {
	return len(messages)
}

func retry(n int) int {
again:
	n--
	if n > 0 {
		goto again
	}
	return n
}
