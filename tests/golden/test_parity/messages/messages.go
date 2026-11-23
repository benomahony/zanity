package parity

import (
	"errors"
	"fmt"
)

// FIXME: this accepts expired credentials.
func compare(a, b int) error {
	if !(a > b) {
		panic("expected a > b")
	}
	if a > 10 {
		return errors.New("invalid input")
	}
	if b > 10 {
		return errors.New("E_TOO_BIG")
	}
	if a < 0 {
		return fmt.Errorf("a must not be negative, since it counts retries, got %d", a)
	}
	return nil
}
