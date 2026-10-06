package shapes

func forward(x int) int {
	return target(x)
}

func (s Session) String() string {
	return fmt.Sprintf("%d", s.n)
}
