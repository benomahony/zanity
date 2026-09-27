package sample

import (
	"math/rand"
	"testing"
	"time"
)

func countdown(n int) int {
	if n < 0 {
		panic("n must not be negative")
	}
	if n > 100 {
		panic("n must be small")
	}
	return countdown(n - 1)
}

func spin() {
	for {
	}
}

func bounded(items []int) {
	for i := 0; i < len(items); i++ {
	}
	for range items {
	}
	for len(items) > 0 {
		items = items[1:]
	}
}

func many(a, b, c, d, e int) int {
	return a + b + c + d + e
}

func forward(x int) int {
	return target(x)
}

func ignore() {
	err := work()
	if err != nil {
	}
}

func TestWaits(t *testing.T) {
	time.Sleep(time.Second)
	_ = rand.Intn(6)
}
