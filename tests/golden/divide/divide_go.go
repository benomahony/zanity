package divide

func Divide(value int, divisor int) int {
    bad := value / 0
    good := value / divisor
    nearZero := value / 0.1
    return bad + good + nearZero
}
